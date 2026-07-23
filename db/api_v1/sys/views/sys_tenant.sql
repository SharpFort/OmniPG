-- db/api_v1/sys/views/sys_tenant
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1.sys_tenant AS
SELECT id, tenant_code, tenant_name, status, contact_email, max_users,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_tenant;
COMMENT ON VIEW api_v1.sys_tenant IS '租户管理视图'；
