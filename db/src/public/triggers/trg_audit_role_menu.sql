-- db/src/public/triggers/trg_audit_role_menu.sql
-- 审计触发器：iam_role_menu 表（角色菜单权限变更；T7: 表名更新）

-- §9 幂等模板: DROP IF EXISTS + CREATE（apply-src 存量库全量重放安全）
DROP TRIGGER IF EXISTS trg_audit_role_menu ON iam_role_menu;
CREATE TRIGGER trg_audit_role_menu
    AFTER INSERT OR UPDATE OR DELETE ON iam_role_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
