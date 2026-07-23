-- db/src/sys/triggers/trg_audit_sys_role.sql
-- 审计触发器：sys_role 表
-- 来源: 20260707000012_audit_triggers.sql

CREATE TRIGGER trg_audit_sys_role
    AFTER INSERT OR UPDATE OR DELETE ON sys_role
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
