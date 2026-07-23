-- db/api_v1/sys/views/sys_user_role
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1.sys_user_role AS
SELECT user_id, role_id, tenant_id, created_at, created_by
FROM public.sys_user_role;
COMMENT ON VIEW api_v1.sys_user_role IS '用户-角色关联视图'；
