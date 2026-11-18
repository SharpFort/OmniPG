-- db/src/platform/triggers/trg_audit_department.sql
-- 审计触发器：department 表（T7: 表名更新）
-- 来源: 20260707000012_audit_triggers.sql

-- §9 幂等模板: DROP IF EXISTS + CREATE（apply-src 存量库全量重放安全）
DROP TRIGGER IF EXISTS trg_audit_department ON department;
CREATE TRIGGER trg_audit_department
    AFTER INSERT OR UPDATE OR DELETE ON department
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
