-- db/src/sys/triggers/trg_audit_sys_role_menu.sql
-- 审计触发器：sys_role_menu 表（角色菜单权限变更）

CREATE TRIGGER trg_audit_sys_role_menu
    AFTER INSERT OR UPDATE OR DELETE ON sys_role_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
