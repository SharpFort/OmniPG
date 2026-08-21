-- api_v1/public/rpc/rpc_list_tenant_members.sql
-- FUNCTION: api_v1_public.rpc_list_tenant_members（17 号文档归位：迁移 035_rpc_cleanup_unify.sql 删定义段，本文件为唯一权威）
-- 回放终态: 035_rpc_cleanup_unify.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_tenant_members(
    p_org_id text DEFAULT NULL, p_query text DEFAULT NULL,
    p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_result json; v_org text;
BEGIN
    IF NOT has_permission('public:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
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
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.joined_at DESC)
            FROM (
                SELECT u.id AS user_id, u.username, u.primary_email AS email,
                       u.primary_phone AS phone, u.name, u.avatar,
                       (NOT u.is_suspended) AS is_active,
                       ut.joined_at
                FROM user_tenants ut
                JOIN users u ON u.id = ut.user_id
                WHERE ut.organization_id = v_org
                  AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%')
                ORDER BY ut.joined_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_tenant_members(text, text, int, int) TO authenticated;
