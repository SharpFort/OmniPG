-- db/src/platform/functions/is_super_admin.sql
-- 超级管理员判定（035 重建：Logto roles 字符串数组语义）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配（Casdoor）→ 030 只重建
--       current_user_roles()（注释声称 is_super_admin 自动恢复，实际漏改）→ 035 重建
-- Casdoor 旧版: isGlobalAdmin/isAdmin 布尔 claim + roles[].name 对象数组（已废弃语义）
-- Logto 版:    roles 为字符串数组（如 ["role_super_admin"]）→ 包含即超管

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT current_user_roles() @> ARRAY['role_super_admin'];
$$;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员（Logto: roles 含 role_super_admin；035 重建——030 声称修复但漏改 is_super_admin 本身）';
