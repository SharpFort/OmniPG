-- db/src/platform/functions/current_tenant_id.sql
-- 当前租户 ID（Logto 语义: 从 JWT claims 的 organization_id 直接提取，F19）
-- 来源: 20260707000008_enable_rls_policies.sql → T7 重写
-- Logto 组织 token 的 organization_id claim（text，21 位 nanoid）即租户上下文。
-- 与 Casdoor 时代差异: 不再查 sys_user_profile（零 fetch，RLS 直接消费 claims）。
-- SECURITY DEFINER 保留（防 RLS 递归——profile 的 policy USING 引用本函数）。

CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS text AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'organization_id', '')
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp;
COMMENT ON FUNCTION current_tenant_id() IS '当前租户 ID（Logto 组织 token: organization_id claim，text）';
