-- db/src/sys/triggers/trg_audit_sys_user_role.sql
-- 审计触发器：sys_user_role 表
-- 来源: 20260707000012_audit_triggers.sql

CREATE TRIGGER trg_audit_sys_user_role
    AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
