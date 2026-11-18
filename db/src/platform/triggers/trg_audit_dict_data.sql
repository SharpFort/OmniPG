-- src/platform/triggers/trg_audit_dict_data.sql
-- TRIGGER: platform.trg_audit_dict_data（17 号文档归位：迁移 023_admin_p0_naming_perm.sql 删定义段，本文件为唯一权威）
-- 回放终态: 023_admin_p0_naming_perm.sql；幂等写法（§9 模板）

-- §9 幂等模板: DROP IF EXISTS + CREATE（apply-src 存量库全量重放安全）
DROP TRIGGER IF EXISTS trg_audit_dict_data ON dict_data;
CREATE TRIGGER trg_audit_dict_data
    AFTER INSERT OR UPDATE OR DELETE ON dict_data
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
