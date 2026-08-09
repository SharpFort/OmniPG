-- =============================================================================
-- 025_admin_sync_tenant_rpc.sql — 租户管理 RPC（05.2 §六 P1 收尾）
-- =============================================================================
-- 背景: 2026-08-04 P1 落地（024 后）
--   rpc_list_tenants / rpc_list_tenant_members（管理端租户管理页）
--   ⚠️ 035 修订: rpc_sync_user_roles 已删除（Logto 无"用户-角色绑定"webhook 事件，
--     无法推送；JIT 覆盖并入 ensure_user——登录时 JWT claims 即 Logto 权威快照；
--     user_role 表由 ensure_user 维护，035 迁移 DROP IF EXISTS 兜底已执行环境）
-- 安全模型:
--   - 租户 RPC 需 sys:tenant:list / sys:tenant-member:list（035 补绑 tenant_admin）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 rpc_list_tenants — 租户列表（分页 + 成员数）
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
-- §2 rpc_list_tenant_members — 租户成员列表
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
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fn int; v_tbl int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_sys'::regnamespace
        AND proname IN ('rpc_list_tenants','rpc_list_tenant_members');
    SELECT count(*) INTO v_tbl FROM pg_tables
      WHERE schemaname='public' AND tablename='user_role';
    RAISE NOTICE '025: 函数=%（期望2） user_role表=%（期望1）', v_fn, v_tbl;
END $$;
