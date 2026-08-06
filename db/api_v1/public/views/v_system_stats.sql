-- db/api_v1/sys/views/v_system_stats.sql
-- 系统统计面板视图（单行汇总）— T7 重写（Logto 镜像表语义）
-- 来源: 20260707000015_system_management_api.sql → T7 适配

CREATE OR REPLACE VIEW api_v1_public.v_system_stats AS
SELECT
    (SELECT COUNT(*) FROM public.tenants WHERE deleted_at IS NULL) AS total_tenants,
    (SELECT COUNT(*) FROM public.users WHERE is_suspended = FALSE) AS active_users,
    (SELECT COUNT(*) FROM public.users) AS total_users,
    (SELECT COUNT(*) FROM public.role) AS total_roles,
    (SELECT COUNT(*) FROM public.department WHERE deleted_at IS NULL) AS total_departments,
    (SELECT COUNT(*) FROM public.iam_menu WHERE is_active) AS total_menus,
    (SELECT COUNT(*) FROM public.iam_api WHERE is_active) AS total_apis,
    now() AS stats_time;
COMMENT ON VIEW api_v1_public.v_system_stats IS '系统统计面板视图（单行汇总，Logto 镜像表）';
