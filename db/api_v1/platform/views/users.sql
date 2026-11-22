DROP VIEW IF EXISTS api_v1_platform.users CASCADE;
-- db/api_v1/platform/views/users.sql
-- D27: 用户 API 输出 dual 列：tenant_id（Logto 租户）+ organization_id（来自 user_profile）。
-- 2026-11-22 上游安全修复（citywalk 扫描 D 组 P0-1）：
--   原视图无 security_invoker、无租户谓词——platform.users 投影 owner=
--   omnipg_logto_reader（BYPASSRLS），owner 链语义绕过 Logto RLS，authenticated
--   经本视图可拉取全租户（含 admin 租户）用户目录（email+手机号）。
--   对照同库样板 public.sys_user（security_invoker=true）。修复三件套：
--   ① security_invoker=true（基表 ACL 以调用方检查，授权面见 zz_grant_all §2）
--   ② 租户谓词 is_super_admin() OR 本租户（strict 版无 claim 返回 NULL → fail-closed）
--   ③ zz_grant_all 对本视图收归管理员角色（role_admin/tenant_admin/super_admin）

CREATE OR REPLACE VIEW api_v1_platform.users WITH (security_invoker = true) AS
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
LEFT JOIN platform.user_profile p ON p.user_id = u.id
WHERE is_super_admin() OR u.tenant_id = current_logto_tenant_id_strict();
-- 兜底：CREATE OR REPLACE 对已存在视图的 reloptions 不保证覆盖，显式 SET 确保幂等生效
ALTER VIEW api_v1_platform.users SET (security_invoker = true);
COMMENT ON VIEW api_v1_platform.users IS '用户表视图（D27：tenant_id=Logto 租户；organization_id=业务组织；security_invoker+租户谓词——超管全量，其余仅本租户，授权仅管理员角色）';
