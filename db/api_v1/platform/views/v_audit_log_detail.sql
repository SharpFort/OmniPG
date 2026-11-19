DROP VIEW IF EXISTS api_v1_platform.v_audit_log_detail CASCADE;
-- db/api_v1/platform/views/v_audit_log_detail.sql
-- D27: 审计日志含 tenant_name（Logto 租户）与 organization_name（业务组织）。
-- 2026-11-19：不设 security_invoker（join platform.users/tenants/organizations，
-- owner 链路含 BYPASSRLS reader）；行级边界由授权收口保证——仅管理员角色可 SELECT
-- （见 zz_grant_all.sql 收权段），super_admin/role_admin 之外不可达。

CREATE OR REPLACE VIEW api_v1_platform.v_audit_log_detail AS
SELECT
    a.id,
    a.table_name,
    a.operation,
    a.old_data,
    a.new_data,
    a.user_id::text AS user_id,
    u.username,
    a.tenant_id,
    a.organization_id,
    t.name AS tenant_name,
    o.name AS organization_name,
    a.created_at
FROM platform.audit_log a
LEFT JOIN platform.users u ON a.user_id::text = u.id
LEFT JOIN platform.tenants t ON a.tenant_id = t.id
LEFT JOIN platform.organizations o ON a.organization_id = o.id
-- 行级边界（2026-11-19 补丁）：owner 链路含 BYPASSRLS reader，视图必须自带租户谓词，
-- 否则管理员角色（role_admin/tenant_admin）经此视图可见全部租户审计行；
-- 超管旁路，普通管理员仅见本租户
WHERE is_super_admin() OR (a.tenant_id = current_logto_tenant_id()
                            AND a.organization_id = current_organization_id());
COMMENT ON VIEW api_v1_platform.v_audit_log_detail IS '审计日志视图（D27：含 tenant_name/organization_name；仅管理员角色 + 行级谓词与 audit_log_read_policy 对齐，见 zz_grant_all.sql 收权段）';
