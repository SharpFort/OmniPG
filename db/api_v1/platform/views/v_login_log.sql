-- api_v1/platform/views/v_login_log.sql
-- VIEW: api_v1_platform.v_login_log（17 号文档归位：迁移 026_view_sys_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 026_view_sys_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_platform.v_login_log AS
SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type, l.result,
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
