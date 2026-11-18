DROP VIEW IF EXISTS api_v1_platform.organizations CASCADE;
-- db/api_v1/platform/views/organizations.sql
-- D27: api_v1_platform.organizations = platform.organizations（Logto Organization）

CREATE OR REPLACE VIEW api_v1_platform.organizations AS
SELECT
    o.id,
    o.id AS organization_id,
    o.tenant_id,
    o.name,
    o.description,
    o.custom_data,
    o.created_at
FROM platform.organizations o;
COMMENT ON VIEW api_v1_platform.organizations IS 'Logto Organization 视图（D27：与 public.organizations 一一对应）';