-- db/api_v1/sys/rpc/rpc_get_user_role_requests.sql
-- 分页查询角色申请列表 RPC（支持状态筛选）
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_user_role_requests(
    p_status text DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_sys.v_role_request_detail 
                  WHERE (p_status IS NULL OR status = p_status)),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(r.*) ORDER BY r.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_sys.v_role_request_detail
                 WHERE (p_status IS NULL OR status = p_status)
                 ORDER BY created_at DESC
                 LIMIT p_limit OFFSET p_offset
             ) r),
            '[]'::json
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_user_role_requests(text, int, int) IS '分页查询角色申请列表（支持状态筛选）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_user_role_requests(text, int, int) TO authenticated;
