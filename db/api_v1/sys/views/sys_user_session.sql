-- db/api_v1/sys/views/sys_user_session
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1.sys_user_session AS
SELECT id, user_id, tenant_id, refresh_token_hash, active_jti, is_used, client_ip, user_agent, created_at, expired_at
FROM public.sys_user_session;
COMMENT ON VIEW api_v1.sys_user_session IS '用户会话视图'；
