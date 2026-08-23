DROP VIEW IF EXISTS api_v1_platform.v_login_log CASCADE;
-- api_v1/platform/views/v_login_log.sql
-- D27: 登录日志 API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.v_login_log AS
SELECT l.id, l.tenant_id, l.organization_id, l.user_id, l.username, l.login_type, l.result,
       l.fail_reason, l.ip, l.user_agent,
       l.region                 AS region_snapshot,
       g->>'region'             AS region_live,
       g->>'source'             AS geo_source,
       (g->>'latitude')::float8 AS latitude,
       (g->>'longitude')::float8 AS longitude,
       g->>'timezone'           AS timezone,
       l.logto_event, l.created_at
FROM login_log l
LEFT JOIN LATERAL geo_locate(l.ip) g ON true;
