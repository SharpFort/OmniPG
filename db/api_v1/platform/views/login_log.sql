DROP VIEW IF EXISTS api_v1_platform.login_log CASCADE;
-- api_v1/platform/views/login_log.sql
-- D27: login_log API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.login_log AS
SELECT id, tenant_id, organization_id, user_id, username, login_type, result, fail_reason,
       ip, user_agent, region, logto_event, created_at
FROM login_log;
