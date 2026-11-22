-- db/api_v1/platform/views/role.sql
-- D27: 角色目录 API = platform.role（Logto roles），输出 tenant_id（Logto 租户）。

DROP VIEW IF EXISTS api_v1_platform.role CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.role AS
SELECT
    r.id,
    r.tenant_id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text                          AS organization_id,
    r.description,
    true::boolean                       AS is_active,
    NULL::timestamptz                   AS deleted_at,
    NULL::text                          AS created_by,
    NULL::text                          AS updated_by,
    NULL::text                          AS deleted_by
FROM platform.role r
-- 租户谓词（2026-11-22 上游安全修复）：无谓词时其他租户角色目录可枚举；
-- 超管全量，其余仅本租户（fail-closed）
WHERE is_super_admin() OR r.tenant_id = current_logto_tenant_id_strict();
COMMENT ON VIEW api_v1_platform.role IS '角色表视图（D27：Logto roles；tenant_id=Logto 租户；organization_id 恒 NULL；租户谓词限定）';
