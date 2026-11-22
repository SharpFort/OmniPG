-- db/api_v1/platform/views/user_tenants.sql
-- D27: 成员关系 API 输出 tenant_id（Logto 租户）与 organization_id（Logto Organization）。

DROP VIEW IF EXISTS api_v1_platform.user_tenants CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.user_tenants AS
SELECT
    ut.user_id,
    ut.tenant_id,
    ut.organization_id
FROM platform.user_tenants ut
-- 租户谓词（2026-11-22 上游安全修复）：platform.user_tenants 投影 owner=BYPASSRLS，
-- 无谓词时全租户用户↔组织关系图可枚举；超管全量，其余仅本租户（fail-closed）
WHERE is_super_admin() OR ut.tenant_id = current_logto_tenant_id_strict();
COMMENT ON VIEW api_v1_platform.user_tenants IS '用户-组织成员关系视图（D27：tenant_id=Logto 租户；organization_id=Logto Organization；租户谓词限定）';
