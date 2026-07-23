-- db/api_v1/sys/views/v_role_list.sql
-- 角色列表视图：含权限数量统计
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE VIEW api_v1.v_role_list AS
SELECT 
    r.id,
    r.role_code,
    r.role_name,
    r.tenant_id,
    r.description,
    r.is_active,
    r.created_at,
    r.updated_at,
    r.deleted_at,
    COALESCE(t.tenant_name, '全局') AS tenant_name,
    (SELECT COUNT(*) FROM public.sys_role_api ra WHERE ra.role_id = r.id) AS api_count,
    (SELECT COUNT(*) FROM public.sys_role_menu rm WHERE rm.role_id = r.id) AS menu_count,
    (SELECT COUNT(*) FROM public.sys_user_role ur WHERE ur.role_id = r.id) AS users_count
FROM public.sys_role r
LEFT JOIN public.sys_tenant t ON r.tenant_id = t.id;
COMMENT ON VIEW api_v1.v_role_list IS '角色列表视图：含权限数量统计';
