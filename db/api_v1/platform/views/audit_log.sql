DROP VIEW IF EXISTS api_v1_platform.audit_log CASCADE;
-- db/api_v1/platform/views/sys_audit_log
-- D27: audit_log API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.audit_log AS
SELECT id, table_name, operation, old_data, new_data, user_id,
       tenant_id, organization_id, created_at
FROM platform.audit_log;
COMMENT ON VIEW api_v1_platform.audit_log IS '审计日志视图（D27：tenant_id=Logto 租户；organization_id=业务组织）';
