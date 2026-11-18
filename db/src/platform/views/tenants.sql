-- db/src/platform/views/tenants.sql
-- D27：platform.tenants = Logto public.tenants（Logto 部署租户，一一对应）
-- 敏感列 db_user_password 不暴露；db_user 仅用于运维排查。

DROP VIEW IF EXISTS platform.tenants CASCADE;
CREATE VIEW platform.tenants AS
SELECT
    t.id,
    t.id AS tenant_id,
    t.name,
    t.tag,
    t.db_user,
    t.created_at,
    t.is_suspended
FROM public.tenants t;
GRANT SELECT ON platform.tenants TO app_owner;
COMMENT ON VIEW platform.tenants IS 'Logto Tenant 只读投影（D27；= public.tenants；不暴露 db_user_password）';