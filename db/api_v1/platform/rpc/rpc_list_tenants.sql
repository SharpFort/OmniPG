-- api_v1/platform/rpc/rpc_list_tenants.sql
-- D27: 业务“租户”= Logto Organization；此 RPC 列组织并输出 tenant_id/logto 租户 + organization_id/组织。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_list_tenants(
    p_query text DEFAULT NULL, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('platform:tenant:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT json_build_object(
        'total', (SELECT count(*) FROM platform.organizations o
                  WHERE (p_query IS NULL OR o.name ILIKE '%' || p_query || '%')
                    AND (current_logto_tenant_id() = 'default' OR o.tenant_id = current_logto_tenant_id())),
        'limit', GREATEST(1, LEAST(p_limit, 100)),
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT o.id AS organization_id, o.name, o.description,
                       o.tenant_id, t.name AS tenant_name, o.created_at,
                       (SELECT count(*) FROM platform.user_tenants ut
                        WHERE ut.organization_id = o.id AND ut.tenant_id = o.tenant_id) AS member_count
                FROM platform.organizations o
                LEFT JOIN platform.tenants t ON o.tenant_id = t.id
                WHERE (p_query IS NULL OR o.name ILIKE '%' || p_query || '%')
                  AND (current_logto_tenant_id() = 'default' OR o.tenant_id = current_logto_tenant_id())
                ORDER BY o.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_list_tenants(text, int, int) TO authenticated;
