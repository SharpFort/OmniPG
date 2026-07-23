-- db/api_v1/sys/views/sys_menu
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_menu AS
SELECT id, parent_id, type, name, path, component, title, icon, permission_code, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_menu;
COMMENT ON VIEW api_v1_sys.sys_menu IS '菜单表视图'；
