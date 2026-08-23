DROP VIEW IF EXISTS api_v1_platform.tenants CASCADE;
-- db/api_v1/platform/views/tenants.sql
-- D27: api_v1_platform.tenants = platform.tenants（Logto 部署租户）

CREATE OR REPLACE VIEW api_v1_platform.tenants AS
SELECT
    t.id,
    t.id AS tenant_id,
    t.name,
    t.tag,
    t.db_user,
    t.created_at,
    t.is_suspended
FROM platform.tenants t;
COMMENT ON VIEW api_v1_platform.tenants IS 'Logto Tenant 视图（D27：与 public.tenants 一一对应；不暴露 db_user_password）';