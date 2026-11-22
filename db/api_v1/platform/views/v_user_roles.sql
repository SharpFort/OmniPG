DROP VIEW IF EXISTS api_v1_platform.v_user_roles CASCADE;
-- db/api_v1/platform/views/v_user_roles.sql
-- D27: 用户→角色分配视图，输出 tenant_id/organization_id 双列。
-- 2026-11-22 上游安全修复（citywalk 扫描 D 组 P0-1）：
--   原视图仅租户过滤无归属过滤（034 注释宣称"RLS=超管OR本人"但未落地）。
--   补齐：① security_invoker=true（基表授权见 zz_grant_all §2，仅 super_admin）
--         ② 归属断言 is_super_admin() OR u.id = current_user_id()（fail-closed：
--            strict/current_user_id 无 claim 返回 NULL 不命中）
--   授权终态不变：仅超管（034 起 authenticated/role_guest/role_editor/role_admin 均未授）

CREATE OR REPLACE VIEW api_v1_platform.v_user_roles WITH (security_invoker = true) AS
SELECT u.id AS user_id, u.username, u.primary_email AS email,
       ur.role_code, ur.role_id, ur.tenant_id, ur.organization_id
FROM platform.users u
LEFT JOIN platform.user_role ur ON ur.user_id = u.id AND ur.tenant_id = u.tenant_id
WHERE u.tenant_id = current_logto_tenant_id_strict()
  AND (is_super_admin() OR u.id = current_user_id());
-- 兜底：CREATE OR REPLACE 对已存在视图的 reloptions 不保证覆盖，显式 SET 确保幂等生效
ALTER VIEW api_v1_platform.v_user_roles SET (security_invoker = true);
