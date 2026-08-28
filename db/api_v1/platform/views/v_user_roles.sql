DROP VIEW IF EXISTS api_v1_platform.v_user_roles CASCADE;
-- db/api_v1/platform/views/v_user_roles.sql
-- D27: 用户→角色分配视图，输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.v_user_roles AS
SELECT u.id AS user_id, u.username, u.primary_email AS email,
       ur.role_code, ur.role_id, ur.tenant_id, ur.organization_id
FROM platform.users u
LEFT JOIN platform.user_role ur ON ur.user_id = u.id AND ur.tenant_id = u.tenant_id
WHERE u.tenant_id = current_logto_tenant_id();
