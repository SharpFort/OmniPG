DROP VIEW IF EXISTS api_v1_platform.organizations CASCADE;
-- db/api_v1/platform/views/organizations.sql
-- D27: api_v1_platform.organizations = platform.organizations（Logto Organization）

CREATE OR REPLACE VIEW api_v1_platform.organizations WITH (security_invoker = true) AS
SELECT
    o.id,
    o.id AS organization_id,
    o.tenant_id,
    o.name,
    o.description,
    o.custom_data,
    o.created_at
FROM platform.organizations o
-- 租户谓词（2026-11-19 修复）：无此过滤时任意 authenticated 可枚举全部租户的组织；
-- 平台层投影（platform.organizations）由 BYPASSRLS reader 拥有，视图必须自带边界
WHERE o.tenant_id = current_logto_tenant_id();
COMMENT ON VIEW api_v1_platform.organizations IS 'Logto Organization 视图（D27；security_invoker + 租户谓词——仅暴露当前 Logto 租户的组织）';