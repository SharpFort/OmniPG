DROP VIEW IF EXISTS api_v1_platform.v_user_role_detail CASCADE;
-- db/api_v1/platform/views/v_user_role_detail.sql
-- D27: 成员详情视图输出 tenant_id/organization_id，并带 Logto 租户名/组织名。

CREATE OR REPLACE VIEW api_v1_platform.v_user_role_detail AS
SELECT
    ut.user_id,
    ut.tenant_id,
    ut.organization_id,
    u.username,
    u.primary_email AS email,
    t.name AS tenant_name,
    o.name AS organization_name
FROM platform.user_tenants ut
JOIN platform.users u ON ut.user_id = u.id
JOIN platform.tenants t ON ut.tenant_id = t.id
JOIN platform.organizations o ON ut.organization_id = o.id
WHERE u.is_suspended = FALSE
-- 租户谓词（2026-11-22 上游安全修复，同批 v_user_list）：投影链 owner=BYPASSRLS，
-- 无谓词时全租户成员详情（含 email）可读；超管全量，其余仅本租户（fail-closed）
  AND (is_super_admin() OR ut.tenant_id = current_logto_tenant_id_strict());
COMMENT ON VIEW api_v1_platform.v_user_role_detail IS '用户-组织成员详情视图（D27：双列 tenant_id/organization_id；租户谓词限定）';
