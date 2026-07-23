-- db/src/sys/triggers/trg_blacklist_on_role_change.sql
-- 角色变更时使旧 Token 失效
-- 来源: 20260707000007_create_security_triggers.sql

CREATE TRIGGER trg_blacklist_on_role_change
AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
FOR EACH ROW EXECUTE FUNCTION blacklist_at_on_role_change();
