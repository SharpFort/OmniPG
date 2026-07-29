-- db/src/sys/triggers/trg_audit_sys_token_blacklist.sql
-- 审计触发器：sys_token_blacklist 表（Token 加入黑名单=踢人操作）

CREATE TRIGGER trg_audit_sys_token_blacklist
    AFTER INSERT ON sys_token_blacklist
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');
