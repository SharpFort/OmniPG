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
-- 源文件: 无（has_permission 惯例，判定函数仅迁移层定义）
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

-- RLS: 宽松读（与 iam_role_api.role_api_read_policy 一致；写经 SECURITY DEFINER RPC）
ALTER TABLE public.iam_role_data_scope ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_data_scope_read_policy ON public.iam_role_data_scope;
CREATE POLICY role_data_scope_read_policy ON public.iam_role_data_scope
FOR SELECT USING (true);

-- ---------------------------------------------------------------------------
-- §2 判定函数 current_data_scope() — 当前用户数据范围（多角色取最宽）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_data_scope() RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles text[];
    v_scope jsonb;
BEGIN
    -- 超管短路
    IF is_super_admin() THEN
        RETURN jsonb_build_object('scope_type', 'all', 'dept_ids', '[]'::jsonb);
    END IF;

    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;

    -- 多角色取最宽: all > dept_and_child > custom > self（RuoYi 同语义）
    SELECT jsonb_build_object(
        'scope_type', CASE
            WHEN bool_or(scope_type = 'all')           THEN 'all'
            WHEN bool_or(scope_type = 'dept_and_child') THEN 'dept_and_child'
            WHEN bool_or(scope_type = 'custom')         THEN 'custom'
            ELSE 'self' END,
        'dept_ids', COALESCE(jsonb_agg(dept_id) FILTER (WHERE dept_id IS NOT NULL), '[]'::jsonb)
    ) INTO v_scope
    FROM iam_role_data_scope
    WHERE role_code = ANY(v_roles);

    IF v_scope IS NULL THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;
    RETURN v_scope;
END;
$$;
COMMENT ON FUNCTION current_data_scope() IS '当前用户数据范围（超管=all；多角色取最宽 all>dept_and_child>custom>self；RLS 部门维度过滤的判定源）';
GRANT EXECUTE ON FUNCTION current_data_scope() TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 判定函数 current_visible_dept_ids() — 当前用户可见部门集合（RLS USING 用）
--    all → 全部门；custom → 指定部门；dept_and_child → 用户部门及其后代
--    （current_user_dept_id() 查 user_profile.dept_id，无部门 → 空集）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_visible_dept_ids() RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH scope AS (
        SELECT scope_type, dept_ids
        FROM jsonb_to_record(current_data_scope()) AS x(scope_type text, dept_ids jsonb)
    )
    -- all: 全部部门
    SELECT d.id FROM department d JOIN scope s ON true WHERE s.scope_type = 'all'
    UNION
    -- custom: 指定部门
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'custom'
      AND d.id IN (SELECT (jsonb_array_elements_text(s.dept_ids))::uuid)
    UNION
    -- dept_and_child: 用户部门及其后代（无部门 → 空集）
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'dept_and_child'
      AND (d.id = current_user_dept_id() OR d.id IN (
          WITH RECURSIVE subtree AS (
              SELECT id FROM department WHERE id = current_user_dept_id()
              UNION ALL
              SELECT c.id FROM department c
              JOIN subtree p ON c.parent_id = p.id
          )
          SELECT id FROM subtree))
$$;
COMMENT ON FUNCTION current_visible_dept_ids() IS '当前用户可见部门 id 集合（RLS USING dept_id IN (SELECT current_visible_dept_ids())；SECURITY DEFINER 防 RLS 递归）';
GRANT EXECUTE ON FUNCTION current_visible_dept_ids() TO authenticated;

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
CREATE OR REPLACE FUNCTION api_v1_public.rpc_get_role_data_scope(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_scope_type text;
    v_depts      json;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT min(scope_type) INTO v_scope_type
    FROM iam_role_data_scope WHERE role_code = p_role_code;
    -- custom 可多行，取任意非 NULL 类型即该角色类型（约束保证同角色类型一致）

    SELECT COALESCE(json_agg(json_build_object('id', d.id, 'name', d.dept_name)
                             ORDER BY d.dept_name), '[]'::json) INTO v_depts
    FROM iam_role_data_scope rs
    JOIN department d ON d.id = rs.dept_id
    WHERE rs.role_code = p_role_code AND rs.dept_id IS NOT NULL;

    RETURN json_build_object(
        'role_code', p_role_code,
        'scope_type', COALESCE(v_scope_type, 'self'),
        'depts', v_depts);
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_get_role_data_scope(text) IS '角色数据范围查询（sys:data-scope:bind；默认 self）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_get_role_data_scope(text) TO authenticated;

-- 4.3 设置（全量覆盖）
CREATE OR REPLACE FUNCTION api_v1_public.rpc_set_role_data_scope(
    p_role_code text, p_scope_type text, p_dept_ids uuid[] DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_dept uuid;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 角色校验同 041（镜像表 OR 已有绑定——镜像同步缺口兜底）
    IF p_role_code IS NULL OR NOT (
        EXISTS (SELECT 1 FROM role WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_api WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_menu WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_data_scope WHERE role_code = p_role_code)
    ) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_scope_type IS NULL OR p_scope_type NOT IN ('all','dept_and_child','self','custom') THEN
        RAISE EXCEPTION 'invalid scope_type' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type = 'custom' AND (p_dept_ids IS NULL OR cardinality(p_dept_ids) = 0) THEN
        RAISE EXCEPTION 'custom scope requires dept_ids' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type <> 'custom' AND p_dept_ids IS NOT NULL AND cardinality(p_dept_ids) > 0 THEN
        RAISE EXCEPTION 'non-custom scope cannot carry dept_ids' USING ERRCODE = '22023';
    END IF;

    -- 全量覆盖（单事务）
    DELETE FROM iam_role_data_scope WHERE role_code = p_role_code;
    IF p_scope_type = 'custom' THEN
        FOREACH v_dept IN ARRAY p_dept_ids LOOP
            IF NOT EXISTS (SELECT 1 FROM department WHERE id = v_dept AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'dept not found: %', v_dept USING ERRCODE = 'P0002';
            END IF;
            INSERT INTO iam_role_data_scope (role_code, scope_type, dept_id, created_by)
            VALUES (p_role_code, 'custom', v_dept, current_user_id());
        END LOOP;
    ELSE
        INSERT INTO iam_role_data_scope (role_code, scope_type, created_by)
        VALUES (p_role_code, p_scope_type, current_user_id());
    END IF;

    PERFORM log_operate('role', 'set-data-scope', 'iam_role_data_scope',
                        p_role_code, 'success',
                        jsonb_build_object('scope_type', p_scope_type, 'dept_count', coalesce(cardinality(p_dept_ids), 0)));
    RETURN json_build_object('ok', true);
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_set_role_data_scope(text, text, uuid[]) IS '角色数据范围设置（全量覆盖；sys:data-scope:bind；custom 须 dept_ids 且部门存在）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_set_role_data_scope(text, text, uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 验证
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
BEGIN
    SELECT count(*) INTO v_tables FROM pg_tables
    WHERE schemaname='public' AND tablename='iam_role_data_scope';
    SELECT count(*) INTO v_constraints FROM pg_constraint
    WHERE conname IN ('iam_role_data_scope_type_check','iam_role_data_scope_dept_consistency');
    SELECT count(*) INTO v_policies FROM pg_policies
    WHERE tablename='iam_role_data_scope';

    -- 造测试部门（RLS 下 SECURITY DEFINER/owner 可绕过）
    INSERT INTO department (id, tenant_id, dept_name) VALUES (v_dept, '__test__', '__smoke_dept__');

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
    DELETE FROM department WHERE id = v_dept;

    RAISE NOTICE '042: 表=% 约束=%（期望2） 策略=%（期望1） custom设置=% 判定=% 可见部门=% 非法值拒绝=% — 全部验证通过',
        v_tables, v_constraints, v_policies, (v_get->>'scope_type'), (v_scope->>'scope_type'), v_visible, v_deny;
END $$;
