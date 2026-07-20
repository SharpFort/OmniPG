-- ==============================================================================
-- Migration 004: pg_notify 通知触发器（实时同步）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 广播函数：当 sys_role_api 变更时发送 pg_notify
-- ==============================================================================
CREATE OR REPLACE FUNCTION notify_policy_reload()
RETURNS TRIGGER AS $$
BEGIN
    -- [修复 P1-5] pg_notify payload 增强为 JSON
    PERFORM pg_notify('casbin_channel', json_build_object(
        'op', TG_OP,
        'table', TG_TABLE_NAME,
        'ts', extract(epoch from now())::bigint
    )::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION notify_policy_reload() IS '发送 casbin_channel 通知，触发 Policy Syncer 实时同步';

-- 绑定触发器到角色-API 关联表
-- FOR EACH STATEMENT 防止批量操作时触发风暴
CREATE TRIGGER trg_reload_on_role_api
AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
FOR EACH STATEMENT EXECUTE FUNCTION notify_policy_reload();

-- migrate:down

DROP TRIGGER IF EXISTS trg_reload_on_role_api ON sys_role_api;
DROP FUNCTION IF EXISTS notify_policy_reload();
