-- db/src/platform/views/user_tenants.sql
-- D27：platform.user_tenants = Logto public.organization_user_relations（用户-组织成员）
-- 双列：tenant_id = Logto 部署租户；organization_id = Logto Organization id。

DROP VIEW IF EXISTS platform.user_tenants CASCADE;
CREATE VIEW platform.user_tenants AS
SELECT
    ut.tenant_id,
    ut.organization_id,
    ut.user_id
FROM public.organization_user_relations ut;
GRANT SELECT ON platform.user_tenants TO app_owner;
COMMENT ON VIEW platform.user_tenants IS '用户-组织成员关系只读投影（D27；tenant_id=Logto 部署租户；organization_id=Logto Organization）';
