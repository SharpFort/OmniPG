DROP VIEW IF EXISTS api_v1_platform.tenants CASCADE;
-- db/api_v1/platform/views/tenants.sql
-- D27: api_v1_platform.tenants = platform.tenants（Logto 部署租户）

CREATE OR REPLACE VIEW api_v1_platform.tenants AS
SELECT
    t.id,
    t.id AS tenant_id,
    t.name,
    t.tag,
    t.db_user,
    t.created_at,
    t.is_suspended
FROM platform.tenants t
-- 租户谓词（2026-11-22 上游安全修复）：无谓词时任意登录用户可枚举全部 Logto 租户
-- （含 db_user/is_suspended 元数据）；超管全量，其余仅本租户（fail-closed）
WHERE is_super_admin() OR t.id = current_logto_tenant_id_strict();
COMMENT ON VIEW api_v1_platform.tenants IS 'Logto Tenant 视图（D27：与 public.tenants 一一对应；不暴露 db_user_password；租户谓词限定）';