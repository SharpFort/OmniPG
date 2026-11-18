DROP VIEW IF EXISTS api_v1_platform.users CASCADE;
-- db/api_v1/platform/views/users.sql
-- D27: 用户 API 输出 dual 列：tenant_id（Logto 租户）+ organization_id（来自 user_profile）。

CREATE OR REPLACE VIEW api_v1_platform.users AS
SELECT
    u.id,
    u.username,
    u.primary_email  AS email,
    u.primary_phone  AS phone,
    u.name,
    u.tenant_id,
    p.organization_id,
    p.dept_id,
    NOT u.is_suspended AS is_active,
    u.created_at,
    u.updated_at,
    NULL::timestamptz AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by,
    NULL::text AS password_hash
FROM platform.users u
LEFT JOIN platform.user_profile p ON p.user_id = u.id;
COMMENT ON VIEW api_v1_platform.users IS '用户表视图（D27：tenant_id=Logto 租户；organization_id=业务组织）';
