-- db/api_v1/sys/views/sys_role_menu
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_role_menu AS
SELECT role_id, menu_id, created_at, created_by
FROM public.sys_role_menu;
COMMENT ON VIEW api_v1_sys.sys_role_menu IS '角色-菜单关联视图'；
