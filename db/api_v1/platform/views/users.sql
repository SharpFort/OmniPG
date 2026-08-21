-- db/api_v1/platform/views/users.sql
-- 数据源: platform.users（Logto 镜像）+ platform.user_profile（业务档案）
-- 来源: 20260707000013_postgrest_api_v1.sql → T7 适配 → 2026-08-20 直连 users + user_profile（不再依赖 platform.sys_user 兼容视图）

CREATE OR REPLACE VIEW api_v1_platform.users AS
SELECT
    u.id,
    u.username,
    u.primary_email  AS email,
    u.primary_phone  AS phone,
    p.tenant_id,
    p.dept_id,
    NOT u.is_suspended AS is_active,
    u.created_at,
    u.logto_updated_at AS updated_at,
    NULL::timestamptz AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by,
    NULL::text AS password_hash              -- 密码由 Logto 管理，仅通过 RPC 访问
FROM platform.users u
LEFT JOIN platform.user_profile p ON p.user_id = u.id;
COMMENT ON VIEW api_v1_platform.users IS '用户表视图（password_hash 仅通过 RPC 访问）';
