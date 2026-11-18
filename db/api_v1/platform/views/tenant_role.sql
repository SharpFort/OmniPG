-- db/api_v1/platform/views/tenant_role.sql
-- D27: 组织角色 API = platform.tenant_role（Logto organization_roles），输出 tenant_id。

DROP VIEW IF EXISTS api_v1_platform.organization_role CASCADE;
DROP VIEW IF EXISTS api_v1_platform.tenant_role CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.tenant_role AS
SELECT
    r.id,
    r.tenant_id,
    r.name AS role_code,
    r.name AS role_name,
    NULL::text AS organization_id,
    r.description,
    r.type::text AS type,
    true::boolean AS is_active,
    NULL::timestamptz AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by
FROM platform.tenant_role r;
COMMENT ON VIEW api_v1_platform.tenant_role IS '组织角色视图（D27：Logto organization_roles；tenant_id=Logto 租户）';
