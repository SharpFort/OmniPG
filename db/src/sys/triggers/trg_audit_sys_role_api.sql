-- db/src/sys/triggers/trg_audit_sys_role_api.sql
-- 审计触发器：sys_role_api 表（权限分配变更直接影响访问控制）

CREATE TRIGGER trg_audit_sys_role_api
    AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
