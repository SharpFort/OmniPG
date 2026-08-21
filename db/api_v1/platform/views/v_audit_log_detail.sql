-- db/api_v1/platform/views/v_audit_log_detail.sql
-- 审计日志视图：含用户名、租户名（T7: users 镜像 + tenants 镜像）
-- 来源: 20260707000015_system_management_api.sql → T7 适配

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
    t.name AS tenant_name,
    a.created_at
FROM platform.audit_log a
LEFT JOIN platform.users u ON a.user_id::text = u.id
LEFT JOIN platform.tenants t ON a.tenant_id = t.id;
COMMENT ON VIEW api_v1_platform.v_audit_log_detail IS '审计日志视图：含用户名、租户名';
