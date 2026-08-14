-- api_v1/public/rpc/rpc_list_tenants.sql
-- FUNCTION: api_v1_public.rpc_list_tenants（17 号文档归位：迁移 035_rpc_cleanup_unify.sql 删定义段，本文件为唯一权威）
-- 回放终态: 035_rpc_cleanup_unify.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_tenants(
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
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT t.id, t.name, t.description, t.created_at,
                       (SELECT count(*) FROM user_tenants ut
                        WHERE ut.organization_id = t.id) AS member_count
                FROM tenants t
                WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'
                ORDER BY t.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_tenants(text, int, int) TO authenticated;
