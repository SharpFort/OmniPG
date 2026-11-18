DROP VIEW IF EXISTS api_v1_platform.v_user_role_detail CASCADE;
-- db/api_v1/platform/views/v_user_role_detail.sql
-- D27: 成员详情视图输出 tenant_id/organization_id，并带 Logto 租户名/组织名。

CREATE OR REPLACE VIEW api_v1_platform.v_user_role_detail AS
SELECT
    ut.user_id,
    ut.tenant_id,
    ut.organization_id,
    u.username,
    u.primary_email AS email,
    t.name AS tenant_name,
    o.name AS organization_name
FROM platform.user_tenants ut
JOIN platform.users u ON ut.user_id = u.id
JOIN platform.tenants t ON ut.tenant_id = t.id
JOIN platform.organizations o ON ut.organization_id = o.id
WHERE u.is_suspended = FALSE;
COMMENT ON VIEW api_v1_platform.v_user_role_detail IS '用户-组织成员详情视图（D27：双列 tenant_id/organization_id）';
