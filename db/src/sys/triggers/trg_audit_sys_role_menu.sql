-- db/src/sys/triggers/trg_audit_sys_role_menu.sql
-- 审计触发器：iam_role_menu 表（角色菜单权限变更；T7: 表名更新）

CREATE TRIGGER trg_audit_sys_role_menu
    AFTER INSERT OR UPDATE OR DELETE ON iam_role_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
