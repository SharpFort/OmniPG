-- api_v1/platform/rpc/rpc_list_tenants.sql
-- D27: 业务“租户”= Logto Organization；此 RPC 列组织并输出 tenant_id/logto 租户 + organization_id/组织。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_list_tenants(
    p_query text DEFAULT NULL, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_result json;
    v_tenant text := current_logto_tenant_id();
    v_is_super boolean := is_super_admin();
    -- P-3e（2026-11-20，阶段 4）：通配符转义——防调用方以 % / _ 前导通配
    -- 强制全表扫描（DoS 面），且修正搜索字面 %/_ 的语义（原拼接把用户输入的
    -- %/_ 当通配符）；ILIKE 默认转义符为反斜杠
    v_pattern text := CASE WHEN p_query IS NULL THEN NULL
        ELSE '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%' END;
BEGIN
    IF NOT has_permission('platform:tenant:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT json_build_object(
        'total', (SELECT count(*) FROM platform.organizations o
                  WHERE (v_pattern IS NULL OR o.name ILIKE v_pattern)
                    AND (v_is_super OR o.tenant_id = v_tenant)),
        'limit', GREATEST(1, LEAST(p_limit, 100)),
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT o.id AS organization_id, o.name, o.description,
                       o.tenant_id, t.name AS tenant_name, o.created_at,
                       -- P-3d（2026-11-20，阶段 4）：member_count 相关标量子查询逐行求值
                       -- （≤100 次/页）→ 预聚合 + LEFT JOIN；COALESCE 保原版"无成员=0"语义
                       COALESCE(mc.member_count, 0) AS member_count
                FROM platform.organizations o
                LEFT JOIN platform.tenants t ON o.tenant_id = t.id
                LEFT JOIN (SELECT organization_id, tenant_id, count(*) AS member_count
                           FROM platform.user_tenants
                           GROUP BY organization_id, tenant_id) mc
                       ON mc.organization_id = o.id AND mc.tenant_id = o.tenant_id
                WHERE (v_pattern IS NULL OR o.name ILIKE v_pattern)
                  AND (v_is_super OR o.tenant_id = v_tenant)
                ORDER BY o.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_list_tenants(text, int, int) TO authenticated;
