-- =============================================================================
-- 049_user_role_refine.sql — D5+D6 user_role 精确镜像（33 号文档 §9 D5/D6）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板（方案 A）——
--   ① user_role 加 organization_id 维度（'' = 全局角色；非空 = 该组织内角色），
--      结构对齐 Logto users_roles（user_id/role_id 形状），复合主键；
--   ② claims 脚本拆 global_roles / org_roles 注入（init-logto.py 同步修改）；
--   ③ JIT 改增量对齐：角色不变零写入、保留 created_at 首次分配时间；
--   ④ 全局 token 登录（无 organization_id）不清组织角色段（防多组织用户丢镜像）。
-- 键设计:
--   PK (user_id, organization_id, role_code)——role_code 为业务键（JWT roles 元素名，
--   恒可用）；role_id 为 Logto 对齐冗余列（可空：镜像缺失时 NULL，对账/后续登录回填），
--   FK → role(id) ON DELETE CASCADE（角色删除级联清理分配镜像，N12 关联项）。
-- 兼容: claims 无 global_roles/org_roles（旧 token 过渡期，claims 脚本未更新前）→
--   跳过角色镜像更新（不写不删），避免把用户角色误清空。
-- 幂等: ADD COLUMN IF NOT EXISTS / DROP CONSTRAINT IF EXISTS / CREATE OR REPLACE。
-- 依赖: role 镜像表（009）、user_profile（012）、ensure_user（035 §7 N7 版，本迁移重写）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 user_role 结构改造
-- ---------------------------------------------------------------------------
ALTER TABLE user_role ADD COLUMN IF NOT EXISTS organization_id text NOT NULL DEFAULT '';
ALTER TABLE user_role ADD COLUMN IF NOT EXISTS role_id text;
COMMENT ON COLUMN user_role.organization_id IS '角色归属维度：'''' = 全局角色（Logto 全局 roles）；非空 = Logto organization id（组织角色）';
COMMENT ON COLUMN user_role.role_id IS 'Logto 角色 id（对齐 users_roles 形状；镜像缺失时 NULL，对账/后续登录回填）';

-- PK 重建: (user_id, role_code) → (user_id, organization_id, role_code)
-- 存量行 organization_id=''，一一对应无冲突
ALTER TABLE user_role DROP CONSTRAINT IF EXISTS user_role_pkey;
ALTER TABLE user_role ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, organization_id, role_code);

-- role_id 对齐 FK（角色删除级联清理分配镜像）
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_role_id_fk') THEN
        ALTER TABLE user_role
        ADD CONSTRAINT user_role_role_id_fk
        FOREIGN KEY (role_id) REFERENCES role(id) ON DELETE CASCADE;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §2 ensure_user 重写（N7 保持 + D5/D6 增量对齐）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims     jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub        text;
    v_org        text;
    v_global     text[];
    v_org_roles  text[];
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    -- N7: users 镜像完全由 webhook（User.*）维护，JIT 仅缺失补建（不覆盖权威值）
    INSERT INTO users (id, username, name, avatar)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', '')
    )
    ON CONFLICT (id) DO NOTHING;

    -- N7: profile 仅在无记录时补建（tenant 归属 = 首次观察到的组织上下文）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;

    -- D5/D6（049）: user_role 精确镜像——global/org 分段增量对齐
    --   · 增量对齐：角色不变零写入、created_at 保留首次分配时间；
    --   · 全局段（organization_id=''）：claims 恒有 global_roles（脚本注入，可为空）→ 空则清空；
    --   · 组织段：仅当本次登录携带组织上下文（v_org 非空）时对齐——全局 token 登录
    --     不清组织段（防多组织用户换上下文登录丢失镜像）；
    --   · 兼容：claims 无 global_roles/org_roles（旧 token）→ 跳过（不写不删）；
    --   · role_id 回填：role 镜像存在时按名取 id（LEFT JOIN），缺失为 NULL 等对账。
    IF v_claims ? 'global_roles' THEN
        v_global := ARRAY(SELECT jsonb_array_elements_text(v_claims->'global_roles'));
        INSERT INTO user_role (user_id, organization_id, role_code, role_id)
        SELECT v_sub, '', g, r.id
        FROM unnest(v_global) AS g
        LEFT JOIN role r ON r.name = g
        WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                          WHERE ur.user_id = v_sub
                            AND ur.organization_id = ''
                            AND ur.role_code = g);
        DELETE FROM user_role
        WHERE user_id = v_sub AND organization_id = ''
          AND role_code NOT IN (SELECT unnest(v_global));
    END IF;

    IF v_claims ? 'org_roles' THEN
        v_org_roles := ARRAY(SELECT jsonb_array_elements_text(v_claims->'org_roles'));
        IF v_org IS NOT NULL THEN
            INSERT INTO user_role (user_id, organization_id, role_code, role_id)
            SELECT v_sub, v_org, g, r.id
            FROM unnest(v_org_roles) AS g
            LEFT JOIN role r ON r.name = g
            WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                              WHERE ur.user_id = v_sub
                                AND ur.organization_id = v_org
                                AND ur.role_code = g);
            DELETE FROM user_role
            WHERE user_id = v_sub AND organization_id = v_org
              AND role_code NOT IN (SELECT unnest(v_org_roles));
        END IF;
    END IF;

    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像精确对齐（035: user_role 随 claims 全量覆盖；049 D5/D6: global/org 分段增量对齐，角色不变零写入，保留 created_at，全局 token 不清 org 段）';
GRANT EXECUTE ON FUNCTION api_v1_public.ensure_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols int; v_pk int; v_fk int; v_fn int;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_role'
      AND column_name IN ('organization_id', 'role_id');
    -- PK 三列完整性由 DROP+ADD PRIMARY KEY DDL 保证（失败即报错）；此处仅查约束存在
    SELECT count(*) INTO v_pk FROM pg_constraint WHERE conname = 'user_role_pkey';
    SELECT count(*) INTO v_fk FROM pg_constraint WHERE conname = 'user_role_role_id_fk';
    SELECT count(*) INTO v_fn FROM pg_proc WHERE proname = 'ensure_user';
    RAISE NOTICE '049: 新增列=% PK=% FK=% ensure_user=%（期望 2/1/1/1）', v_cols, v_pk, v_fk, v_fn;
    IF v_cols <> 2 OR v_pk <> 1 OR v_fk <> 1 OR v_fn <> 1 THEN
        RAISE EXCEPTION '049 验证失败';
    END IF;
    RAISE NOTICE '049: 全部验证通过';
END $$;
