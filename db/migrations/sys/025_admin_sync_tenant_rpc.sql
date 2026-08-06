-- =============================================================================
-- 025_admin_sync_tenant_rpc.sql — 角色镜像同步 + 租户管理 RPC（05.2 §六 P1 收尾）
-- =============================================================================
-- 背景: 2026-08-04 P1 落地（024 后）
--   rpc_sync_user_roles（分配镜像 JIT 覆盖，05 §6.5 / P1-12）
--   rpc_list_tenants / rpc_list_tenant_members（管理端租户管理页）
-- 安全模型:
--   - rpc_sync_user_roles() 无参 = 本人 JIT 同步（读 claims roles，服务端权威，防伪造）
--   - rpc_sync_user_roles(p_user_id) = 管理端主动同步（需 sys:user-role:sync）
--   - 租户 RPC 需 sys:tenant:list / sys:tenant-member:list
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 rpc_sync_user_roles — 分配镜像 JIT 覆盖（05 §6.5 策略 ②）
--     claims roles（Logto 权威，含全部隐式路径）→ user_role 全量覆盖
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_sync_user_roles(p_user_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_target text;
    v_roles  text[];
BEGIN
    -- 无参 = 本人同步（前端登录后调用一次，幂等；读 claims 防伪造）
    v_target := COALESCE(p_user_id, current_user_id());
    IF v_target IS NULL THEN
        RAISE EXCEPTION 'no identity' USING ERRCODE = '42501';
    END IF;

    IF p_user_id IS NOT NULL AND p_user_id <> current_user_id()
       AND NOT has_permission('sys:user-role:sync') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    -- 目标用户的 roles：本人从 claims 读；他人由管理端传入？不——他人由 Logto 权威，
    -- 此处仅支持本人 JIT（管理端主动同步走对账脚本 P2）。防伪造：他人同步需权限点 + roles 从
    -- 何处来？Management API 对账（P1-15 失败对账同管道）——本函数保持"本人 JIT 覆盖"单一职责。
    IF p_user_id IS NOT NULL AND p_user_id <> current_user_id() THEN
        RAISE EXCEPTION 'target user sync via reconciliation job only' USING ERRCODE = '22023';
    END IF;

    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    -- 全量覆盖（JIT 语义：claims 是当前权威快照）
    DELETE FROM user_role WHERE user_id = v_target;
    IF v_roles IS NOT NULL THEN
        INSERT INTO user_role (user_id, role_code)
        SELECT v_target, g FROM unnest(v_roles) AS g
        ON CONFLICT (user_id, role_code) DO NOTHING;
    END IF;

    PERFORM log_operate('role', 'sync-mirror', 'user_role', v_target,
                        'success', jsonb_build_object('roles', v_roles));
    RETURN json_build_object('ok', true, 'user_id', v_target, 'roles', v_roles);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_sync_user_roles(text) IS '用户角色镜像 JIT 覆盖（本人：读 claims roles 防伪造；管理端同步他人走 P2 对账任务，本函数拒绝）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_sync_user_roles(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §2 rpc_list_tenants — 租户列表（分页 + 成员数）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_list_tenants(
    p_query text DEFAULT NULL, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('sys:tenant:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT json_build_object(
        'total', (SELECT count(*) FROM tenants t
                  WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT t.id, t.name, t.description, t.created_at,
                       (SELECT count(*) FROM user_tenants ut
                        WHERE ut.organization_id = t.id) AS member_count
                FROM tenants t
                WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'
                ORDER BY t.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 200)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_list_tenants(text, int, int) IS '租户列表（分页 + 成员数；sys:tenant:list）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_list_tenants(text, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 rpc_list_tenant_members — 租户成员列表
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_list_tenant_members(
    p_org_id text DEFAULT NULL, p_query text DEFAULT NULL,
    p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_result json; v_org text;
BEGIN
    IF NOT has_permission('sys:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 默认当前租户；指定 org 需超管或该租户成员（管理员）
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM user_tenants ut
                  WHERE ut.organization_id = v_org
                    AND (p_query IS NULL OR EXISTS (
                        SELECT 1 FROM users u WHERE u.id = ut.user_id
                        AND (u.username ILIKE '%' || p_query || '%'
                          OR u.primary_email ILIKE '%' || p_query || '%')))),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.joined_at DESC)
            FROM (
                SELECT u.id AS user_id, u.username, u.primary_email AS email,
                       u.primary_phone AS phone, u.name, u.avatar,
                       (NOT u.is_suspended) AS is_active,
                       ut.created_at AS joined_at
                FROM user_tenants ut
                JOIN users u ON u.id = ut.user_id
                WHERE ut.organization_id = v_org
                  AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%')
                ORDER BY ut.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 500)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_list_tenant_members(text, text, int, int) IS '租户成员列表（默认当前租户；指定 org 需超管或该租户成员；sys:tenant-member:list）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_list_tenant_members(text, text, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fn int; v_tbl int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_sys'::regnamespace
        AND proname IN ('rpc_sync_user_roles','rpc_list_tenants','rpc_list_tenant_members');
    SELECT count(*) INTO v_tbl FROM pg_tables
      WHERE schemaname='public' AND tablename='user_role';
    RAISE NOTICE '025: 函数=%（期望3） user_role表=%（期望1）', v_fn, v_tbl;
END $$;
