-- db/src/sys/functions/notify_policy_reload.sql
-- 发送 casbin_channel 通知，触发 Policy Syncer 实时同步
-- 来源: 20260707000004_create_notify_triggers.sql

CREATE OR REPLACE FUNCTION notify_policy_reload()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('casbin_channel', json_build_object(
        'op', TG_OP,
        'table', TG_TABLE_NAME,
        'ts', extract(epoch from now())::bigint
    )::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION notify_policy_reload() IS '发送 casbin_channel 通知，触发 Policy Syncer 实时同步';
