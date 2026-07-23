-- db/src/sys/functions/current_tenant_id.sql
-- 从 JWT 中提取当前租户 ID
-- 来源: 20260707000008_enable_rls_policies.sql

CREATE OR REPLACE FUNCTION current_tenant_id() 
RETURNS uuid AS $$
    SELECT (current_setting('request.jwt.claims', true)::json->>'tenant_id')::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_tenant_id() IS '从 JWT 中提取当前租户 ID';
