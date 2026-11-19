DROP VIEW IF EXISTS api_v1_platform.login_log CASCADE;
-- api_v1/platform/views/login_log.sql
-- D27: login_log API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.login_log WITH (security_invoker = true) AS
SELECT id, tenant_id, organization_id, user_id, username, login_type, result, fail_reason,
       ip, user_agent, region, logto_event, created_at
FROM platform.login_log;
COMMENT ON VIEW api_v1_platform.login_log IS '登录日志视图（D27 双列；security_invoker——行级边界由 login_log RLS 提供）';
