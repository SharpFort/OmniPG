-- db/api_v1/sys/views/sys_token_blacklist
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_token_blacklist AS
SELECT jti, blacklisted_at, expired_at, reason, user_id
FROM public.sys_token_blacklist;
COMMENT ON VIEW api_v1_sys.sys_token_blacklist IS 'Token 黑名单视图（只读）'；
