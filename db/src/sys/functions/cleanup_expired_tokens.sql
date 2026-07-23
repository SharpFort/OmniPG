-- db/src/sys/functions/cleanup_expired_tokens.sql
-- 清理过期的 Token 黑名单和会话（由 pg_cron 定时调用）
-- 来源: 20260707000007_create_security_triggers.sql

CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS void AS $$
BEGIN
    DELETE FROM sys_token_blacklist WHERE expired_at < now();
    DELETE FROM sys_user_session WHERE expired_at < now() - interval '1 day';
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION cleanup_expired_tokens() IS '清理过期的 Token 黑名单和会话（由 pg_cron 定时调用）';
