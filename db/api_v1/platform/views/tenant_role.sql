-- db/api_v1/platform/views/tenant_role.sql
-- D27: 组织角色 API = platform.tenant_role（Logto organization_roles），输出 tenant_id。

DROP VIEW IF EXISTS api_v1_platform.organization_role CASCADE;
DROP VIEW IF EXISTS api_v1_platform.tenant_role CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.tenant_role AS
SELECT
    r.id,
    r.tenant_id,
    r.name AS role_code,
    r.name AS role_name,
    NULL::text AS organization_id,
    r.description,
    r.type::text AS type,
    true::boolean AS is_active,
    NULL::timestamptz AS deleted_at,
    NULL::text AS created_by,
    NULL::text AS updated_by,
    NULL::text AS deleted_by
FROM platform.tenant_role r
-- 租户谓词（2026-11-22 上游安全修复）：无谓词时其他租户组织角色可枚举；
-- 超管全量，其余仅本租户（fail-closed）
WHERE is_super_admin() OR r.tenant_id = current_logto_tenant_id_strict();
COMMENT ON VIEW api_v1_platform.tenant_role IS '组织角色视图（D27：Logto organization_roles；tenant_id=Logto 租户；租户谓词限定）';
