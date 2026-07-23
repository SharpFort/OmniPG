-- db/api_v1/sys/rpc/rpc_get_online_users.sql
-- 获取在线用户列表 RPC（分页）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_online_users(
    p_limit int DEFAULT 50,
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
        'total', (SELECT COUNT(*) FROM api_v1_sys.v_online_users),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(u.*) ORDER BY u.session_created_at DESC)
             FROM (
                 SELECT * FROM api_v1_sys.v_online_users
                 ORDER BY session_created_at DESC
                 LIMIT p_limit OFFSET p_offset
             ) u),
            '[]'::json
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_online_users(int, int) IS '获取在线用户列表（分页）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_online_users(int, int) TO authenticated;
