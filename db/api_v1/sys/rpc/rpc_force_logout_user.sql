-- db/api_v1/sys/rpc/rpc_force_logout_user.sql
-- 强制用户下线 RPC（加入黑名单并标记会话）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.force_logout_user(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_count int;
BEGIN
    WITH blacklisted AS (
        INSERT INTO public.sys_token_blacklist (jti, expired_at, reason, user_id)
        SELECT s.active_jti, s.expired_at, 'force_logout', s.user_id
        FROM public.sys_user_session s
        WHERE s.user_id = p_user_id
          AND s.is_used = FALSE
          AND s.active_jti IS NOT NULL
        ON CONFLICT (jti) DO NOTHING
        RETURNING jti
    )
    SELECT COUNT(*) INTO v_count FROM blacklisted;
    
    UPDATE public.sys_user_session
    SET is_used = TRUE
    WHERE user_id = p_user_id AND is_used = FALSE;
    
    RETURN json_build_object(
        'user_id', p_user_id,
        'sessions_revoked', v_count
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.force_logout_user(uuid) IS '强制用户下线（加入黑名单并标记会话）';
GRANT EXECUTE ON FUNCTION api_v1_sys.force_logout_user(uuid) TO authenticated;
