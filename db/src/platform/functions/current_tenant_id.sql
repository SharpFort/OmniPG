-- db/src/platform/functions/current_tenant_id.sql
-- D27：保留函数名（兼容历史代码），语义 = 当前 Logto Organization id（业务组织）。
-- 来源：request.jwt.claims->>'organization_id'（Logto 组织 token 内置 claim，F19）。
-- 若需严格的“Logto 部署租户”，请使用 current_logto_tenant_id()。

CREATE OR REPLACE FUNCTION current_tenant_id()
RETURNS text AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'organization_id', '')
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp;
COMMENT ON FUNCTION current_tenant_id() IS '当前业务组织（Logto Organization）ID；保留名兼容历史代码，D27 后请优先使用 current_organization_id()';
