-- db/src/sys/functions/blacklist_at_on_role_change.sql
-- 角色变更触发器：将旧 JWT 的 jti 写入黑名单，迫使客户端无感刷新
-- 来源: 20260707000007_create_security_triggers.sql

CREATE OR REPLACE FUNCTION blacklist_at_on_role_change()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_session RECORD;
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        v_user_id := NEW.user_id;
    ELSE
        v_user_id := OLD.user_id;
    END IF;

    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = v_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at, reason, user_id)
        VALUES (v_session.active_jti, v_session.expired_at, 'role_changed', v_user_id)
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION blacklist_at_on_role_change() IS '角色变更触发器：将旧 JWT 的 jti 写入黑名单，迫使客户端无感刷新';
