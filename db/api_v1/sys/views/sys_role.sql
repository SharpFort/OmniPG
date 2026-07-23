-- db/api_v1/sys/views/sys_role
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1.sys_role AS
SELECT id, role_code, role_name, tenant_id, description, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_role;
COMMENT ON VIEW api_v1.sys_role IS '角色表视图'；
