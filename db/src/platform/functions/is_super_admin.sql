-- db/src/platform/functions/is_super_admin.sql
-- 超级管理员判定（035 重建：Logto roles 字符串数组语义）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配（Casdoor）→ 030 只重建
--       current_user_roles()（注释声称 is_super_admin 自动恢复，实际漏改）→ 035 重建
-- Casdoor 旧版: isGlobalAdmin/isAdmin 布尔 claim + roles[].name 对象数组（已废弃语义）
-- Logto 版:    roles 为字符串数组（如 ["role_super_admin"]）→ 包含即超管
-- P-2d（2026-11-20，阶段 4 函数级优化）：原版经 current_user_roles() 数组展开后
--   @> 判定——RLS 策略里逐行调用时每次做 jsonb_array_elements_text 子查询；
--   改为 jsonb 包含判定（roles @> ["role_super_admin"]，语义同字符串数组成员，
--   数值/对象元素场景恒 false）——纯表达式零子查询，无 search_path 依赖。
--   语义差异（加固方向）：roles 为标量（非数组）时原版报错，现版恒 false
--   （fail-closed：RLS 策略不再因畸形 claims 整查询报错，落入租户谓词判定）。

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb -> 'roles', '[]'::jsonb)
           @> '["role_super_admin"]'::jsonb
$$;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员（Logto: roles 含 role_super_admin；P-2d：jsonb 包含判定，纯表达式零子查询，畸形 claims fail-closed）';
