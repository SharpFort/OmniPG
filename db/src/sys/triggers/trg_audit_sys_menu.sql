-- db/src/sys/triggers/trg_audit_sys_menu.sql
-- 审计触发器：sys_menu 表（菜单变更影响所有用户的前端导航）

CREATE TRIGGER trg_audit_sys_menu
    AFTER INSERT OR UPDATE OR DELETE ON sys_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();
