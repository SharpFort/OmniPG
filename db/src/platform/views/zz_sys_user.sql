-- src/platform/views/sys_user.sql
-- VIEW: platform.sys_user —— 兼容视图（保留历史命名，非 sys 模块/非物理表）
-- D27: 输出 u.tenant_id（Logto 租户）+ p.organization_id（业务组织）。
-- 2026-11-19 修复：CREATE OR REPLACE → DROP IF EXISTS + CREATE——D27 调整了列序，
-- 对旧列序库重放 CREATE OR REPLACE 会报 42P16（无法重命名/重排列）；本视图为
-- 无依赖兼容视图，重建安全（platform 表级授权由 _init_schema 兜底重放）。
-- CASCADE：已部署库若残留依赖对象，非级联 DROP 会让重放失败（2026-11-19 修补）

DROP VIEW IF EXISTS platform.sys_user CASCADE;
CREATE VIEW platform.sys_user
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
FROM platform.users u
LEFT JOIN platform.user_profile p ON p.user_id = u.id;

-- DROP+CREATE 会丢弃 ACL（2026-11-19 修补）：_init_schema 的全量授权在本文件之前重放，
-- 不会自动补齐——此处立即按原授权面恢复（对齐 _init_schema 的 platform 表授权角色集）
GRANT SELECT ON platform.sys_user TO authenticated, role_admin, role_editor, role_guest, super_admin;
