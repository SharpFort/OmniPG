-- db/api_v1/sys/views/sys_role_api
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_role_api AS
SELECT role_id, api_id, created_at, created_by
FROM public.sys_role_api;
COMMENT ON VIEW api_v1_sys.sys_role_api IS '角色-API 关联视图'；
