-- db/src/sys/functions/check_token_blacklist.sql
-- PostgREST db-pre-request 黑名单拦截函数
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION check_token_blacklist()
RETURNS void AS $$
DECLARE
    v_jti varchar;
BEGIN
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    -- 仅拦截未过期的黑名单 jti
    IF v_jti IS DISTINCT FROM NULL AND EXISTS (
        SELECT 1 FROM sys_token_blacklist WHERE jti = v_jti AND expired_at > now()
    ) THEN
        RAISE EXCEPTION 'Token Has Been Revoked' USING ERRCODE = 'P0001';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION check_token_blacklist() IS 'db-pre-request 拦截函数：检测 JWT 的 jti 是否在黑名单中';
