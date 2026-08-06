-- db/src/sys/triggers/trg_audit_role_api.sql
-- 审计触发器：iam_role_api 表（权限分配变更直接影响访问控制；T7: 表名更新）

CREATE TRIGGER trg_audit_role_api
    AFTER INSERT OR UPDATE OR DELETE ON iam_role_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
