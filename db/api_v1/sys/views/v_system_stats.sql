-- db/api_v1/sys/views/v_system_stats.sql
-- 系统统计面板视图（单行汇总）
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE VIEW api_v1_sys.v_system_stats AS
SELECT 
    (SELECT COUNT(*) FROM public.sys_tenant WHERE deleted_at IS NULL) AS total_tenants,
    (SELECT COUNT(*) FROM public.sys_tenant WHERE status = 'active' AND deleted_at IS NULL) AS active_tenants,
    (SELECT COUNT(*) FROM public.sys_user WHERE deleted_at IS NULL) AS total_users,
    (SELECT COUNT(*) FROM public.sys_user WHERE is_active = TRUE AND deleted_at IS NULL) AS active_users,
    (SELECT COUNT(*) FROM public.sys_role WHERE deleted_at IS NULL) AS total_roles,
    (SELECT COUNT(*) FROM public.sys_department WHERE deleted_at IS NULL) AS total_departments,
    (SELECT COUNT(*) FROM public.sys_menu WHERE deleted_at IS NULL) AS total_menus,
    (SELECT COUNT(*) FROM public.sys_api WHERE deleted_at IS NULL) AS total_apis,
    (SELECT COUNT(*) FROM public.sys_user_session WHERE is_used = FALSE AND expired_at > now()) AS online_users,
    (SELECT COUNT(*) FROM public.sys_user_role_request WHERE status = 'pending') AS pending_requests,
    now() AS stats_time;
COMMENT ON VIEW api_v1_sys.v_system_stats IS '系统统计面板视图（单行汇总）';
