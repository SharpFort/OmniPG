-- db/src/sys/functions/kick_user.sql
-- 强制踢下线：将该用户所有活跃会话的 Access Token 加入黑名单
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION kick_user(p_user_id uuid)
RETURNS boolean AS $$
DECLARE
    v_session RECORD;
BEGIN
    -- 将该用户所有活跃会话的 AT jti 加入黑名单
    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = p_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at, reason, user_id)
        VALUES (v_session.active_jti, v_session.expired_at, 'kicked', p_user_id)
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    -- 标记所有活跃 RT 已使用
    UPDATE sys_user_session SET is_used = TRUE WHERE user_id = p_user_id AND is_used = FALSE;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION kick_user(uuid) IS '强制踢下线：将该用户所有活跃会话的 Access Token 加入黑名单';
