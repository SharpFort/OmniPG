-- db/api_v1/sys/views/sys_api
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_api AS
SELECT id, path, method, api_name, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_api;
COMMENT ON VIEW api_v1_sys.sys_api IS 'API 资源表视图'；
