-- db/src/sys/triggers/trg_audit_sys_api.sql
-- 审计触发器：sys_api 表（API 资源变更影响安全边界）

CREATE TRIGGER trg_audit_sys_api
    AFTER INSERT OR UPDATE OR DELETE ON sys_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
