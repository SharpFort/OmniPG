-- db/src/platform/views/role.sql
-- D25/D27：platform.role = Logto public.roles（全部 Logto Tenant）
-- role_code = Logto roles.name；tenant_id = Logto 部署租户。

DROP VIEW IF EXISTS platform.role CASCADE;
CREATE VIEW platform.role AS
SELECT
    r.id,
    r.tenant_id,
    r.name,
    r.name AS role_code,
    r.description,
    r.type::text AS type,
    r.is_default
FROM public.roles r;
GRANT SELECT ON platform.role TO app_owner;
COMMENT ON VIEW platform.role IS 'Logto 全局角色只读投影（D27；全部 Logto Tenant；role_code=name；含 MachineToMachine）';
