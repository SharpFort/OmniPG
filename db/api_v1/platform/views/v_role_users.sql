DROP VIEW IF EXISTS api_v1_platform.v_role_users CASCADE;
-- db/api_v1/platform/views/v_role_users.sql
-- D27: 全局角色→用户分配，按 role_id + tenant_id + organization_id='' 关联。

CREATE OR REPLACE VIEW api_v1_platform.v_role_users AS
SELECT r.name AS role_code, r.id AS role_id, r.tenant_id, r.type::text AS role_type,
       ur.user_id, u.username, ur.tenant_id AS assignment_tenant_id, ur.organization_id AS assignment_organization_id
FROM platform.role r
LEFT JOIN platform.user_role ur ON ur.role_id = r.id AND ur.tenant_id = r.tenant_id AND ur.organization_id = ''
LEFT JOIN platform.users u ON u.id = ur.user_id
WHERE r.tenant_id = current_logto_tenant_id();
