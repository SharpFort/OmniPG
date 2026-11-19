-- db/api_v1/platform/views/sys_cron_log
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_platform.cron_job_log WITH (security_invoker = true) AS
SELECT id, job_name, execution_time, result, duration_ms
FROM platform.cron_job_log;
-- 兜底：CREATE OR REPLACE 对已存在视图的 reloptions 不保证覆盖，显式 SET 确保幂等生效
ALTER VIEW api_v1_platform.cron_job_log SET (security_invoker = true);
COMMENT ON VIEW api_v1_platform.cron_job_log IS 'Cron 执行日志视图（只读；security_invoker——行级边界由 cron_job_log RLS 提供，见 rls_policies.sql）';
