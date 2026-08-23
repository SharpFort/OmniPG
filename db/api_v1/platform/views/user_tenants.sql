-- db/api_v1/platform/views/user_tenants.sql
-- D27: 成员关系 API 输出 tenant_id（Logto 租户）与 organization_id（Logto Organization）。

DROP VIEW IF EXISTS api_v1_platform.user_tenants CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.user_tenants AS
SELECT
    ut.user_id,
    ut.tenant_id,
    ut.organization_id
FROM platform.user_tenants ut;
COMMENT ON VIEW api_v1_platform.user_tenants IS '用户-组织成员关系视图（D27：tenant_id=Logto 租户；organization_id=Logto Organization）';
