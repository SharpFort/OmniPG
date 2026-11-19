DROP VIEW IF EXISTS api_v1_platform.v_login_log CASCADE;
-- api_v1/platform/views/v_login_log.sql
-- D27: 登录日志 API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.v_login_log WITH (security_invoker = true) AS
SELECT l.id, l.tenant_id, l.organization_id, l.user_id, l.username, l.login_type, l.result,
       l.fail_reason, l.ip, l.user_agent,
       l.region                 AS region_snapshot,
       g->>'region'             AS region_live,
       g->>'source'             AS geo_source,
       -- 数值列防护性解析（2026-11-19 修复）：geo 数据异常时不再让整视图报 22P02，
       -- 非数值载荷按 NULL 处理
       CASE WHEN g->>'latitude'  ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            THEN (g->>'latitude')::float8  END AS latitude,
       CASE WHEN g->>'longitude' ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            THEN (g->>'longitude')::float8 END AS longitude,
       g->>'timezone'           AS timezone,
       l.logto_event, l.created_at
FROM platform.login_log l
LEFT JOIN LATERAL platform.geo_locate(l.ip) g ON true;
