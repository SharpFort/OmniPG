-- db/src/sys/triggers/trg_audit_sys_user_role_request.sql
-- 审计触发器：sys_user_role_request 表（审批流审计）

CREATE TRIGGER trg_audit_sys_user_role_request
    AFTER INSERT OR UPDATE OR DELETE ON sys_user_role_request
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
