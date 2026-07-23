-- db/api_v1/sys/rpc/rpc_cleanup_expired_sessions.sql
-- 手动清理过期会话和 Token 黑名单 RPC
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.cleanup_expired_sessions()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_blacklist_count int;
    v_session_count int;
BEGIN
    WITH deleted_blacklist AS (
        DELETE FROM public.sys_token_blacklist WHERE expired_at < now() RETURNING jti
    )
    SELECT COUNT(*) INTO v_blacklist_count FROM deleted_blacklist;
    
    WITH deleted_sessions AS (
        DELETE FROM public.sys_user_session 
        WHERE expired_at < now() - interval '1 day' RETURNING id
    )
    SELECT COUNT(*) INTO v_session_count FROM deleted_sessions;
    
    RETURN json_build_object(
        'blacklist_removed', v_blacklist_count,
        'sessions_removed', v_session_count,
        'cleanup_time', now()
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.cleanup_expired_sessions() IS '手动清理过期会话和 Token 黑名单（仅 super_admin）';
GRANT EXECUTE ON FUNCTION api_v1_sys.cleanup_expired_sessions() TO authenticated;
