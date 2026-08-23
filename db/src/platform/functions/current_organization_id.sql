-- db/src/platform/functions/current_organization_id.sql
-- D27：当前 Logto Organization id（业务组织）
-- = current_tenant_id()；名称与 organization_id 列对齐。

CREATE OR REPLACE FUNCTION current_organization_id()
RETURNS text AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'organization_id', '')
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp;
COMMENT ON FUNCTION current_organization_id() IS '当前 Logto Organization ID（业务组织；与 DB organization_id 列对齐）';
