-- src/public/triggers/trg_audit_iam_api.sql
-- TRIGGER: public.trg_audit_iam_api（17 号文档归位：迁移 023_admin_p0_naming_perm.sql 删定义段，本文件为唯一权威）
-- 回放终态: 023_admin_p0_naming_perm.sql；幂等写法（§9 模板）

CREATE TRIGGER trg_audit_iam_api
    AFTER INSERT OR UPDATE OR DELETE ON iam_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
