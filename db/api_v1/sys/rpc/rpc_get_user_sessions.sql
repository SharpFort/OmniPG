-- db/api_v1/sys/rpc/rpc_get_user_sessions.sql
-- 获取用户会话列表 RPC（只能查看自己的，除非 super_admin）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_user_sessions(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    IF p_user_id != current_user_id() AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'Permission denied' USING ERRCODE = 'P0005';
    END IF;
    
    SELECT COALESCE(json_agg(
        json_build_object(
            'id', s.id,
            'active_jti', s.active_jti,
            'client_ip', s.client_ip,
            'user_agent', s.user_agent,
            'created_at', s.created_at,
            'expired_at', s.expired_at,
            'is_used', s.is_used,
            'is_active', s.is_used = FALSE AND s.expired_at > now()
        ) ORDER BY s.created_at DESC
    ), '[]'::json) INTO v_result
    FROM public.sys_user_session s
    WHERE s.user_id = p_user_id;
    
    RETURN json_build_object('user_id', p_user_id, 'sessions', v_result);
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_user_sessions(uuid) IS '获取用户会话列表（只能查看自己的，除非 super_admin）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_user_sessions(uuid) TO authenticated;
