-- src/platform/views/sys_user.sql
-- VIEW: platform.sys_user —— 兼容视图（保留历史命名，非 sys 模块/非物理表）
-- D27: 输出 u.tenant_id（Logto 租户）+ p.organization_id（业务组织）。

CREATE OR REPLACE VIEW platform.sys_user
WITH (security_invoker = true) AS
SELECT
    u.id,
    u.tenant_id,
    u.username,
    NULL::text AS password_hash,
    p.organization_id,
    p.dept_id,
    u.primary_email  AS email,
    u.primary_phone  AS phone,
    NOT u.is_suspended AS is_active,
    u.created_at,
    u.updated_at AS updated_at,
    NULL::timestamptz AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by
FROM users u
LEFT JOIN user_profile p ON p.user_id = u.id;
