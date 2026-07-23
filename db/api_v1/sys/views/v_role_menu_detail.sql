-- db/api_v1/sys/views/v_role_menu_detail.sql
-- 角色-菜单关联详情视图
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE VIEW api_v1_sys.v_role_menu_detail AS
SELECT 
    rm.role_id,
    rm.menu_id,
    rm.created_at,
    r.role_code,
    r.role_name,
    m.name AS menu_name,
    m.type AS menu_type,
    m.title AS menu_title,
    m.permission_code,
    m.parent_id AS menu_parent_id
FROM public.sys_role_menu rm
JOIN public.sys_role r ON rm.role_id = r.id
JOIN public.sys_menu m ON rm.menu_id = m.id
WHERE r.deleted_at IS NULL AND m.deleted_at IS NULL;
COMMENT ON VIEW api_v1_sys.v_role_menu_detail IS '角色-菜单关联详情视图';
