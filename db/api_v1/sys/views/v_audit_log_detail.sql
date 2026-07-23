-- db/api_v1/sys/views/v_audit_log_detail.sql
-- 审计日志视图：含用户名、租户名
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE VIEW api_v1_sys.v_audit_log_detail AS
SELECT 
    a.id,
    a.table_name,
    a.operation,
    a.old_data,
    a.new_data,
    a.user_id,
    u.username,
    a.tenant_id,
    t.tenant_name,
    a.created_at
FROM public.sys_audit_log a
LEFT JOIN public.sys_user u ON a.user_id = u.id
LEFT JOIN public.sys_tenant t ON a.tenant_id = t.id;
COMMENT ON VIEW api_v1_sys.v_audit_log_detail IS '审计日志视图：含用户名、租户名';
