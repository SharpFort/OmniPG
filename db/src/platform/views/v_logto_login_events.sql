-- db/src/platform/views/v_logto_login_events.sql
-- D27：Logto public.logs 的 TriggerHook.PostSignIn 原始事件（含 tenant_id）
-- 主登录日志页面仍走 platform.login_log（PostSignIn webhook 写入 + region 快照），
-- 本视图仅用于运维排查 Logto 原始登录事件。

DROP VIEW IF EXISTS platform.v_logto_login_events;
CREATE VIEW platform.v_logto_login_events AS
SELECT
    l.tenant_id,
    l.payload->>'userId' AS user_id,
    l.payload->'user'->>'username' AS username,
    l.payload->>'userIp' AS ip,
    l.payload->>'userAgent' AS user_agent,
    l.payload->>'createdAt' AS logto_created_at,
    l.payload->'application'->>'id' AS application_id,
    l.payload->>'result' AS result,
    l.created_at AS created_at
FROM public.logs l
WHERE l.key = 'TriggerHook.PostSignIn';
GRANT SELECT ON platform.v_logto_login_events TO app_owner;
COMMENT ON VIEW platform.v_logto_login_events IS 'Logto PostSignIn 原始事件只读投影（D27；含 tenant_id；运维排查用）';
