-- =============================================================================
-- 051_logto_guard_cleanup.sql — P2 治理：N18 乱序守护 + N21 空转跳过 + N14 RPC
-- =============================================================================
-- 覆盖项（33 号文档 §3/§6 P2 治理）:
--   N18: 镜像表加 logto_updated_at（权威 updatedAt），sync_* 乱序守护——
--        "旧事件不覆盖新状态"（Logto 重试/Replay 可能乱序）；
--   N21: sync_membership_delta 空 delta 早退（无变更事件不空转）；
--        5000 截断的 sys_config 标记移除——D9 对账任务每日全量成员对账兜底（标记冗余）；
--   N14: rpc_get_user_roles（SECURITY DEFINER + sys:tenant-member:list 门槛 + 同租户约束）
--        替代裸视图——租户管理员可查本租户用户角色分配（v_user_roles RLS 仅超管/本人）；
--   N11/N12: 注释固化决策——joined_at=now() 本地近似（Logto 成员 API 不返回加入时间）；
--        角色硬删 + user_role FK CASCADE 显式级联清理绑定（049 已建 FK）。
-- 乱序守护语义:
--   · logto_updated_at = COALESCE(logto_ts(data->>'updatedAt'), now())
--     （webhook 无 updatedAt → 本地时间近似；对账 payload 携带 → 权威时间）；
--   · ON CONFLICT UPDATE 追加 WHERE 旧行 logto_updated_at IS NULL（存量兼容）
--     OR EXCLUDED.logto_updated_at >= 旧行值（>= 允许同时间戳乱序内覆盖）；
--   · 守护只挡"更旧事件"，sync_* 幂等性保持。
-- 依赖: sync_*（047/048/050 版，本迁移重写）；has_permission/current_tenant_id
--       （024/035，rpc_get_user_roles 用）。
-- 幂等: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE 可重放。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 logto_updated_at 列（N18）
-- ---------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE role ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
ALTER TABLE organization_role ADD COLUMN IF NOT EXISTS logto_updated_at timestamptz;
COMMENT ON COLUMN users.logto_updated_at IS 'Logto 权威 updatedAt（webhook 无该字段时为本地近似）；乱序守护比较基准（N18）';
COMMENT ON COLUMN tenants.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
COMMENT ON COLUMN role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
COMMENT ON COLUMN organization_role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';

-- N11 决策注释（Logto 成员 API 不返回加入时间——joined_at 为首次观察到成员关系的本地时间）
COMMENT ON COLUMN user_tenants.joined_at IS '加入时间（本地近似）——Logto 成员 API 不返回加入时间；对账全量重建时保持首次观察值（N11 决策）';

-- N12 决策注释（角色硬删 + FK CASCADE 显式级联清理绑定，与用户/组织软删策略区分）
COMMENT ON TABLE role IS 'Logto 全局角色镜像（只读投影）；删除策略=硬删+级联——user_role.role_id FK ON DELETE CASCADE 显式清理分配镜像（N12 决策，049 建立）';

-- ---------------------------------------------------------------------------
-- §2 sync_user_upsert 重写（N18 乱序守护）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO users (id, username, primary_email, primary_phone, name, avatar,
                       custom_data, identities, last_sign_in_at, created_at, application_id,
                       is_suspended, profile, sso_identities, updated_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'username', ''),
        COALESCE(data->>'primaryEmail', ''),
        COALESCE(data->>'primaryPhone', ''),
        COALESCE(data->>'name', ''),
        COALESCE(data->>'avatar', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(data->'identities', '{}'),
        logto_ts(data->>'lastSignInAt'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        COALESCE(data->>'applicationId', ''),
        COALESCE((data->>'isSuspended')::boolean, false),
        COALESCE(data->'profile', '{}'),
        COALESCE(data->'ssoIdentities', '{}'),
        v_ts, v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        username        = EXCLUDED.username,
        primary_email   = EXCLUDED.primary_email,
        primary_phone   = EXCLUDED.primary_phone,
        name            = EXCLUDED.name,
        avatar          = EXCLUDED.avatar,
        custom_data     = EXCLUDED.custom_data,
        identities      = EXCLUDED.identities,
        last_sign_in_at = EXCLUDED.last_sign_in_at,
        application_id  = EXCLUDED.application_id,
        is_suspended    = EXCLUDED.is_suspended,
        profile         = EXCLUDED.profile,
        sso_identities  = EXCLUDED.sso_identities,
        updated_at      = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE users.logto_updated_at IS NULL                       -- 存量兼容（首次同步）
       OR EXCLUDED.logto_updated_at >= users.logto_updated_at; -- 乱序守护（N18）
END $$;
COMMENT ON FUNCTION sync_user_upsert(jsonb) IS 'Logto 用户镜像 upsert（051 N18: logto_updated_at 乱序守护——旧事件不覆盖新状态）';

-- ---------------------------------------------------------------------------
-- §3 sync_role_upsert 重写（N18）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO role (id, name, description, type, is_default, created_at, updated_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now(),
        v_ts, v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        type             = EXCLUDED.type,
        is_default       = EXCLUDED.is_default,
        updated_at       = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE role.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= role.logto_updated_at;
END $$;
COMMENT ON FUNCTION sync_role_upsert(jsonb) IS 'Logto 角色目录镜像 upsert（051 N18: 乱序守护）';

-- ---------------------------------------------------------------------------
-- §4 sync_tenant_upsert 重写（N18）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_tenant_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO tenants (id, name, description, custom_data, created_at, updated_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        v_ts, v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        custom_data      = EXCLUDED.custom_data,
        updated_at       = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE tenants.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= tenants.logto_updated_at;
END $$;
COMMENT ON FUNCTION sync_tenant_upsert(jsonb) IS 'Logto 组织镜像 upsert（051 N18: 乱序守护）';

-- ---------------------------------------------------------------------------
-- §5 sync_organization_role_upsert 重写（N18）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_organization_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO organization_role (id, name, description, created_at, updated_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        now(),
        v_ts, v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        updated_at       = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE organization_role.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= organization_role.logto_updated_at;
END $$;
COMMENT ON FUNCTION sync_organization_role_upsert(jsonb) IS '组织角色镜像 upsert（051 N18: 乱序守护）';

-- ---------------------------------------------------------------------------
-- §6 sync_user_suspension 重写（N18：封禁事件同样受乱序守护）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_suspension(p_user_id text, p_suspended boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE users
       SET is_suspended   = COALESCE(p_suspended, false),
           updated_at     = now(),
           logto_updated_at = now()
     WHERE id = p_user_id
       AND (logto_updated_at IS NULL OR now() >= logto_updated_at);
END $$;
COMMENT ON FUNCTION sync_user_suspension(text, boolean) IS '封禁状态镜像同步（051 N18: 乱序守护）';

-- ---------------------------------------------------------------------------
-- §7 sync_membership_delta 重写（N21：空 delta 早退；移除 5000 截断标记）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_membership_delta(
    org_id  text,
    added   jsonb,
    removed jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user_id text;
BEGIN
    -- N21: 缺失字段视为无变更（Logto 无变更事件也可能推送 Membership.Updated）
    IF added IS NULL OR jsonb_typeof(added) <> 'array' THEN
        added := '[]'::jsonb;
    END IF;
    IF removed IS NULL OR jsonb_typeof(removed) <> 'array' THEN
        removed := '[]'::jsonb;
    END IF;

    -- N21: 空 delta 早退（无变更不空转）
    IF jsonb_array_length(added) = 0 AND jsonb_array_length(removed) = 0 THEN
        RETURN;
    END IF;

    -- 新增成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(added)
    LOOP
        INSERT INTO user_tenants (organization_id, user_id)
        VALUES (org_id, v_user_id)
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- 移除成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(removed)
    LOOP
        DELETE FROM user_tenants
        WHERE organization_id = org_id AND user_id = v_user_id;
    END LOOP;
END $$;
COMMENT ON FUNCTION sync_membership_delta(text, jsonb, jsonb) IS '成员关系增量同步（051 N21: 空 delta 早退；5000 截断由 D9 对账每日全量兜底，sys_config 标记已移除）';

-- ---------------------------------------------------------------------------
-- §8 rpc_get_user_roles（N14：管理端角色-成员页查询通道，替代裸视图）
--     门槛: sys:tenant-member:list + 同租户约束（与 rpc_list_tenant_members 一致）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_get_user_roles(p_user_id text, p_org_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_org        text;
    v_global     json;
    v_org_roles  json;
BEGIN
    IF NOT has_permission('sys:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    -- 同租户约束：跨租户查询仅超管可越权
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_global
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = '') x;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_org_roles
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = v_org) x;

    RETURN json_build_object(
        'user_id',  p_user_id,
        'org_id',   v_org,
        'global_roles', v_global,
        'org_roles',    v_org_roles
    );
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_get_user_roles(text, text) IS '用户角色分配查询（N14: SECURITY DEFINER + sys:tenant-member:list + 同租户约束；global 段 + 当前 org 段）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_get_user_roles(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §9 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols int; v_fn int;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('users', 'tenants', 'role', 'organization_role')
      AND column_name = 'logto_updated_at';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('sync_user_upsert', 'sync_role_upsert', 'sync_tenant_upsert',
                      'sync_organization_role_upsert', 'sync_user_suspension',
                      'sync_membership_delta', 'rpc_get_user_roles');
    RAISE NOTICE '051: logto_updated_at列=% 函数=%（期望 4/7）', v_cols, v_fn;
    IF v_cols <> 4 OR v_fn <> 7 THEN
        RAISE EXCEPTION '051 验证失败';
    END IF;
    RAISE NOTICE '051: 全部验证通过';
END $$;
