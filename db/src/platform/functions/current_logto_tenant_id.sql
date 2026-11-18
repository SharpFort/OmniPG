-- db/src/platform/functions/current_logto_tenant_id.sql
-- D27：当前 Logto 部署租户 ID
-- 优先读 request.jwt.claims->>'tenant_id'（需 init-logto.py Custom Claims 注入）；
-- 未注入时回退 'default'（当前业务默认 Logto Tenant）。
-- TODO：Logto customizer 可注入 tenant_id claim 后，此处即支持 default/admin 双租户运行时路由。

CREATE OR REPLACE FUNCTION current_logto_tenant_id()
RETURNS text AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'tenant_id', ''),
        'default'
    )
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp;
COMMENT ON FUNCTION current_logto_tenant_id() IS '当前 Logto 部署租户 ID（优先 claims tenant_id，回退 default）';
