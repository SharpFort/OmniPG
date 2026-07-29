-- db/src/sys/triggers/trg_audit_sys_user_session.sql
-- 审计触发器：sys_user_session 表（会话管理操作审计）

CREATE TRIGGER trg_audit_sys_user_session
    AFTER INSERT OR UPDATE OR DELETE ON sys_user_session
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
