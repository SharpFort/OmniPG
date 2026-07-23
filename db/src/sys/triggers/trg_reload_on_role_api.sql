-- db/src/sys/triggers/trg_reload_on_role_api.sql
-- 角色-API 变更时发送 pg_notify
-- 来源: 20260707000004_create_notify_triggers.sql

CREATE TRIGGER trg_reload_on_role_api
AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
FOR EACH STATEMENT EXECUTE FUNCTION notify_policy_reload();
