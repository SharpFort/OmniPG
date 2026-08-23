DROP VIEW IF EXISTS api_v1_platform.v_user_list CASCADE;
-- db/api_v1/platform/views/v_user_list.sql
-- D27: 用户列表输出 tenant_id（Logto 租户）与 organization_id（业务组织）。

CREATE OR REPLACE VIEW api_v1_platform.v_user_list AS
SELECT
    u.id,
    u.username,
    u.primary_email AS email,
    u.primary_phone AS phone,
    u.name,
    u.tenant_id,
    p.organization_id,
    p.dept_id,
    o.name AS organization_name,
    t.name AS tenant_name,
    d.dept_name,
    (NOT u.is_suspended) AS is_active,
    u.created_at,
    u.updated_at,
    NULL::timestamptz AS deleted_at,
    COALESCE(
        (SELECT json_agg(ut.organization_id ORDER BY ut.organization_id)
         FROM platform.user_tenants ut
         WHERE ut.user_id = u.id AND ut.tenant_id = u.tenant_id),
        '[]'::json
    ) AS organizations
FROM platform.users u
LEFT JOIN platform.user_profile p ON p.user_id = u.id
LEFT JOIN platform.organizations o ON p.organization_id = o.id
LEFT JOIN platform.tenants t ON u.tenant_id = t.id
LEFT JOIN platform.department d ON p.dept_id = d.id;
COMMENT ON VIEW api_v1_platform.v_user_list IS '用户列表视图（D27：tenant_id=Logto 租户；organization_id=业务组织；organizations=组织 id 列表）';
