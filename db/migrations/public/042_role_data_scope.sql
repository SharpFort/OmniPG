-- =============================================================================
-- 042_role_data_scope.sql — 数据权限表 + 判定函数框架（P1，2026-08-09 用户拍板"现在就做"）
-- =============================================================================
-- 背景: 菜单/API 管理优化结论落地（建议 4；对照 SharpFort Role.DataScope +
--       RoleDepartment / BladeX blade_scope_data / RuoYi DataScope 1-5 级）
--   现状缺口: RLS 只有租户级隔离（tenant_id），无"本部门及以下/仅本人/自定义部门"
--   决策:
--     D1 表: iam_role_data_scope（授权域 iam_ 前缀——019 命名规则"iam_=授权判定数据"）
--     D2 scope_type 四值封闭: all(全部) / dept_and_child(本部门及以下) /
--        self(仅本人) / custom(自定义部门，dept_id 多行)
--     D3 判定函数 current_data_scope()/current_visible_dept_ids() 为 RLS 策略框架
--        （本期交付框架，业务表部门级过滤按需后续逐个挂——见 §6 模板）
--     D4 管理 RPC: rpc_get/set_role_data_scope（全量覆盖；新权限点 sys:data-scope:bind）
--     D5 角色校验同 041（镜像表 OR 已有绑定——镜像同步缺口兜底）
-- 命名: 与 RuoYi DataScope 对齐（all=1全部/dept_and_child=4本部门及以下/
--       self=5仅本人/custom=2自定义；3本部门=dept_and_child 特例含自身）
-- 17 号文档归位登记（2026-08-14，§6.2 情形 a，P0-8）:
--   · current_data_scope/current_visible_dept_ids → db/src/public/functions/（+GRANT）
--   · rpc_get/set_role_data_scope → db/api_v1/public/rpc/（+GRANT）
--   · role_data_scope_read_policy → db/src/public/privileges/rls_policies.sql
--   · scope_type TEXT+CHECK → 原生 ENUM：类型见 db/src/public/types/scope_type.sql
--     （bootstrap 前置），列转换 + CHECK 移除见迁移 059（§8.6 流程）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_role_data_scope 表（幂等）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_role_data_scope (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    role_code   text NOT NULL,                          -- Logto 角色名（join key，同 iam_role_api）
    scope_type  text NOT NULL DEFAULT 'self',           -- all / dept_and_child / self / custom
    dept_id     uuid REFERENCES department(id) ON DELETE CASCADE,  -- custom 时指定（可多行）
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text,
    CONSTRAINT iam_role_data_scope_type_check
        CHECK (scope_type IN ('all','dept_and_child','self','custom')),
    CONSTRAINT iam_role_data_scope_dept_consistency
        CHECK ((scope_type = 'custom' AND dept_id IS NOT NULL)
            OR (scope_type <> 'custom' AND dept_id IS NULL)),
    UNIQUE (role_code, scope_type, dept_id)
);
COMMENT ON TABLE iam_role_data_scope IS '角色数据范围（授权判定数据；RLS 部门维度过滤的依据）';
COMMENT ON COLUMN iam_role_data_scope.scope_type IS '数据范围: all=全部 / dept_and_child=本部门及以下 / self=仅本人 / custom=自定义部门';
COMMENT ON COLUMN iam_role_data_scope.dept_id IS 'custom 时指定部门（一个角色可多行）；其余类型恒 NULL（约束保证）';

CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_role ON iam_role_data_scope(role_code);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_dept ON iam_role_data_scope(dept_id);

-- RLS: role_data_scope_read_policy 归位 → db/src/public/privileges/rls_policies.sql（17 号文档，2026-08-14）
-- ---------------------------------------------------------------------------
-- §2 判定函数 current_data_scope() — 当前用户数据范围（多角色取最宽）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §3 判定函数 current_visible_dept_ids() — 当前用户可见部门集合（RLS USING 用）
--    all → 全部门；custom → 指定部门；dept_and_child → 用户部门及其后代
--    （current_user_dept_id() 查 user_profile.dept_id，无部门 → 空集）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §4 管理 RPC（权限点 sys:data-scope:bind）
-- ---------------------------------------------------------------------------
-- 4.1 新权限点注册 + 超管绑定（011 种子"超管绑全部权限点"的增量，幂等）
INSERT INTO iam_api (path, method, name, description, api_code, menu_id, api_group, created_by)
SELECT '/rpc/sys:data-scope:bind', 'POST', '数据范围-绑定',
       '角色数据范围配置（all/dept_and_child/self/custom）', 'sys:data-scope:bind',
       m.id, '角色管理', NULL
FROM iam_menu m WHERE m.menu_name = 'RoleList'
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id, created_by)
SELECT 'role_super_admin', a.id, NULL
FROM iam_api a WHERE a.api_code = 'sys:data-scope:bind'
ON CONFLICT (role_code, api_id) DO NOTHING;

-- 4.2 查询
-- 4.3 设置（全量覆盖）
-- ---------------------------------------------------------------------------
-- §5 验证（结构断言 + 函数行为环境自适应——函数已迁 src，dbmate up 阶段
--     不存在则跳过行为段；059 移除 type_check 后约束计数 = 1）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tables     int;
    v_constraints int;
    v_policies   int;
    v_dept       uuid := uuidv7();
    v_scope      jsonb;
    v_get        json;
    v_visible    int;
    v_deny       boolean;
    v_fn_exists  boolean;
BEGIN
    SELECT count(*) INTO v_tables FROM pg_tables
    WHERE schemaname='public' AND tablename='iam_role_data_scope';
    SELECT count(*) INTO v_constraints FROM pg_constraint
    WHERE conname = 'iam_role_data_scope_dept_consistency';
    SELECT count(*) INTO v_policies FROM pg_policies
    WHERE tablename='iam_role_data_scope';

    -- 函数存在性（环境自适应：src 重放时存在，dbmate up 阶段不存在）
    v_fn_exists := to_regprocedure('api_v1_public.rpc_set_role_data_scope(text,text,uuid[])') IS NOT NULL;

    -- 造测试部门（RLS 下 SECURITY DEFINER/owner 可绕过）
    INSERT INTO department (id, tenant_id, dept_name) VALUES (v_dept, '__test__', '__smoke_dept__');

    IF v_fn_exists THEN
        -- 设置: tenant_admin custom [v_dept]（tenant_admin 已有 14 条 role_api 绑定 → 校验通过）
        PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
        PERFORM api_v1_public.rpc_set_role_data_scope('tenant_admin', 'custom', ARRAY[v_dept]);
        v_get := api_v1_public.rpc_get_role_data_scope('tenant_admin');
        IF (v_get->>'scope_type') <> 'custom' OR json_array_length(v_get->'depts') <> 1 THEN
            RAISE EXCEPTION '042 验证失败: set/get custom（%s）', v_get::text;
        END IF;

        -- 判定: tenant_admin claims → custom 且 dept_ids 含 v_dept；可见集合含 v_dept
        PERFORM set_config('request.jwt.claims', '{"roles":["tenant_admin"]}', true);
        v_scope := current_data_scope();
        IF (v_scope->>'scope_type') <> 'custom' OR NOT (v_scope->'dept_ids') @> to_jsonb(v_dept::text) THEN
            RAISE EXCEPTION '042 验证失败: current_data_scope（%）', v_scope::text;
        END IF;
        SELECT count(*) INTO v_visible FROM current_visible_dept_ids() AS vis(dept_id) WHERE dept_id = v_dept;
        IF v_visible <> 1 THEN
            RAISE EXCEPTION '042 验证失败: current_visible_dept_ids 缺测试部门';
        END IF;

        -- 超管短路: all
        PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
        IF (current_data_scope()->>'scope_type') <> 'all' THEN
            RAISE EXCEPTION '042 验证失败: 超管应 all';
        END IF;

        -- 非法值拒绝: bad scope_type（超管短路后仍走 22023 校验）
        BEGIN
            PERFORM api_v1_public.rpc_set_role_data_scope('tenant_admin', 'bad_type');
            v_deny := false;
        EXCEPTION WHEN invalid_parameter_value THEN
            v_deny := true;
        END;

        -- 清理
        DELETE FROM iam_role_data_scope WHERE role_code = 'tenant_admin' AND scope_type = 'custom';
    END IF;
    DELETE FROM department WHERE id = v_dept;

    RAISE NOTICE '042: 表=% 约束=%（期望1） 策略=% 函数存在=% custom设置=% 判定=% 可见部门=% 非法值拒绝=%',
        v_tables, v_constraints, v_policies, v_fn_exists, (v_get->>'scope_type'), (v_scope->>'scope_type'), v_visible, v_deny;
END $$;
