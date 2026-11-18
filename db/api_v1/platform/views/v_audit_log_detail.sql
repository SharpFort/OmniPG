DROP VIEW IF EXISTS api_v1_platform.v_audit_log_detail CASCADE;
-- db/api_v1/platform/views/v_audit_log_detail.sql
-- D27: 审计日志含 tenant_name（Logto 租户）与 organization_name（业务组织）。

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
LEFT JOIN platform.organizations o ON a.organization_id = o.id;
COMMENT ON VIEW api_v1_platform.v_audit_log_detail IS '审计日志视图（D27：含 tenant_name/organization_name）';
