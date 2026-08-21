-- db/api_v1/platform/views/sys_audit_log
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_platform.audit_log AS
SELECT id, table_name, operation, old_data, new_data, user_id, tenant_id, created_at
FROM platform.audit_log;
COMMENT ON VIEW api_v1_platform.audit_log IS '审计日志视图（只读）';
