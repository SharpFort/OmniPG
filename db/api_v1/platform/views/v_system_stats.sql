DROP VIEW IF EXISTS api_v1_platform.v_system_stats CASCADE;
-- db/api_v1/platform/views/v_system_stats.sql
-- D27: 统计同时含 Logto Tenant 数与 Organization 数。

CREATE OR REPLACE VIEW api_v1_platform.v_system_stats AS
SELECT
    -- 计数谓词（2026-11-22 上游安全修复）：投影链 owner=BYPASSRLS，原子查询无谓词
    -- 时跨租户计数（用户/租户/组织总数）对任意持授权角色可见；超管=平台全量，
    -- 其余=本租户口径（iam_menu 为全局菜单，无租户列，不谓词化）
    (SELECT COUNT(*) FROM platform.tenants
      WHERE is_super_admin() OR id = current_logto_tenant_id_strict()) AS total_tenants,
    (SELECT COUNT(*) FROM platform.organizations
      WHERE is_super_admin() OR tenant_id = current_logto_tenant_id_strict()) AS total_organizations,
    (SELECT COUNT(*) FROM platform.users
      WHERE is_suspended = FALSE
        AND (is_super_admin() OR tenant_id = current_logto_tenant_id_strict())) AS active_users,
    (SELECT COUNT(*) FROM platform.users
      WHERE is_super_admin() OR tenant_id = current_logto_tenant_id_strict()) AS total_users,
    (SELECT COUNT(*) FROM platform.role
      WHERE is_super_admin() OR tenant_id = current_logto_tenant_id_strict()) AS total_roles,
    (SELECT COUNT(*) FROM platform.department
      WHERE deleted_at IS NULL
        AND (is_super_admin() OR tenant_id = current_logto_tenant_id_strict())) AS total_departments,
    (SELECT COUNT(*) FROM platform.iam_menu WHERE is_active) AS total_menus,
    (SELECT COUNT(*) FROM platform.iam_menu WHERE is_active AND api_url IS NOT NULL) AS total_apis,
    now() AS stats_time;
COMMENT ON VIEW api_v1_platform.v_system_stats IS '系统统计面板视图（D27：total_tenants=Logto Tenant；total_organizations=Logto Organization；计数谓词=超管全量/其余本租户；授权仅管理员角色）';
