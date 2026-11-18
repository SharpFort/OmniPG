-- db/src/platform/views/organizations.sql
-- D27：platform.organizations = Logto public.organizations（业务租户/组织，一一对应）
-- Organization 位于 Tenant 之下：tenant_id = Logto 部署租户 id。

DROP VIEW IF EXISTS platform.organizations CASCADE;
CREATE VIEW platform.organizations AS
SELECT
    o.id,
    o.id AS organization_id,
    o.name,
    o.description,
    o.custom_data,
    o.tenant_id AS tenant_id,
    o.created_at
FROM public.organizations o;
GRANT SELECT ON platform.organizations TO app_owner;
COMMENT ON VIEW platform.organizations IS 'Logto Organization 只读投影（D27；= public.organizations；organization_id 的权威来源）';