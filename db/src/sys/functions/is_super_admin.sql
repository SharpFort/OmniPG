-- db/src/sys/functions/is_super_admin.sql
-- 超级管理员判定（Phase 1: 适配 Casdoor JWT）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配
-- Casdoor JWT: isGlobalAdmin/isAdmin 布尔 claim；roles 为角色对象数组
-- Phase 1 修复: NULLIF 空串兜底（claims 缺失/为空时返回 false 而非报错，
--               避免 web_anon 无 token 请求触发 pre-request/RLS 时崩溃）

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean AS $$
    SELECT COALESCE(
        (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'isGlobalAdmin')::boolean,
        (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'isAdmin')::boolean,
        EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
                COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->'roles', '[]'::jsonb)
            ) AS r
            WHERE r->>'name' IN ('super_admin', 'admin')
        ),
        false
    );
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员（Casdoor isGlobalAdmin/isAdmin/角色，Phase 1 适配）';
