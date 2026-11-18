DROP VIEW IF EXISTS api_v1_platform.v_system_stats CASCADE;
-- db/api_v1/platform/views/v_system_stats.sql
-- D27: 统计同时含 Logto Tenant 数与 Organization 数。

CREATE OR REPLACE VIEW api_v1_platform.v_system_stats AS
SELECT
    (SELECT COUNT(*) FROM platform.tenants) AS total_tenants,
    (SELECT COUNT(*) FROM platform.organizations) AS total_organizations,
    (SELECT COUNT(*) FROM platform.users WHERE is_suspended = FALSE) AS active_users,
    (SELECT COUNT(*) FROM platform.users) AS total_users,
    (SELECT COUNT(*) FROM platform.role) AS total_roles,
    (SELECT COUNT(*) FROM platform.department WHERE deleted_at IS NULL) AS total_departments,
    (SELECT COUNT(*) FROM platform.iam_menu WHERE is_active) AS total_menus,
    (SELECT COUNT(*) FROM platform.iam_menu WHERE is_active AND api_url IS NOT NULL) AS total_apis,
    now() AS stats_time;
COMMENT ON VIEW api_v1_platform.v_system_stats IS '系统统计面板视图（D27：total_tenants=Logto Tenant；total_organizations=Logto Organization）';
