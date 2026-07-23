-- db/api_v1/sys/views/sys_secret
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_secret AS
SELECT key_name FROM public.sys_secret;
COMMENT ON VIEW api_v1_sys.sys_secret IS '密钥表视图（仅暴露 key_name）'；
