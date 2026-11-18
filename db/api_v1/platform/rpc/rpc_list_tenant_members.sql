-- api_v1/platform/rpc/rpc_list_tenant_members.sql
-- D27: 组织成员列表：p_organization_id（业务组织），输出 tenant_id/organization_id 双列。

DROP FUNCTION IF EXISTS api_v1_platform.rpc_list_tenant_members(text, text, int, int);
CREATE OR REPLACE FUNCTION api_v1_platform.rpc_list_tenant_members(
    p_organization_id text DEFAULT NULL, p_query text DEFAULT NULL,
    p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_result json; v_org text; v_tenant text := current_logto_tenant_id();
BEGIN
    IF NOT has_permission('platform:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_organization_id, current_organization_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF p_organization_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_organization_id
                         AND tenant_id = v_tenant) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM platform.user_tenants ut
                  WHERE ut.organization_id = v_org AND ut.tenant_id = v_tenant
                    AND (p_query IS NULL OR EXISTS (
                        SELECT 1 FROM platform.users u WHERE u.id = ut.user_id
                        AND (u.username ILIKE '%' || p_query || '%'
                          OR u.primary_email ILIKE '%' || p_query || '%')))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.username)
            FROM (
                SELECT u.id AS user_id, u.username, u.primary_email AS email,
                       u.primary_phone AS phone, u.name, u.avatar,
                       (NOT u.is_suspended) AS is_active,
                       ut.tenant_id, ut.organization_id
                FROM platform.user_tenants ut
                JOIN platform.users u ON u.id = ut.user_id
                WHERE ut.organization_id = v_org AND ut.tenant_id = v_tenant
                  AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%')
                ORDER BY u.username
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_list_tenant_members(text, text, int, int) TO authenticated;
