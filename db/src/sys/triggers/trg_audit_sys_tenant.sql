-- db/src/sys/triggers/trg_audit_sys_tenant.sql
-- 审计触发器：sys_tenant 表（租户操作是最高危操作，必须审计）

CREATE TRIGGER trg_audit_sys_tenant
    AFTER INSERT OR UPDATE OR DELETE ON sys_tenant
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
