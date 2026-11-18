-- db/src/platform/views/tenant_role.sql
-- D27：platform.tenant_role = Logto public.organization_roles（组织角色，全部 Logto Tenant）
-- tenant_id = Logto 部署租户；name 可作 role_code。

DROP VIEW IF EXISTS platform.tenant_role CASCADE;
CREATE VIEW platform.tenant_role AS
SELECT
    o.id,
    o.tenant_id,
    o.name,
    o.description,
    o.type::text AS type
FROM public.organization_roles o;
GRANT SELECT ON platform.tenant_role TO app_owner;
COMMENT ON VIEW platform.tenant_role IS '组织角色只读投影（D27；= Logto OrganizationRoles；tenant_id=Logto 部署租户）';
