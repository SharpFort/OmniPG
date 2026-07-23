-- db/api_v1/sys/views/sys_cron_log
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_cron_log AS
SELECT id, job_name, execution_time, result, duration_ms
FROM public.sys_cron_log;
COMMENT ON VIEW api_v1_sys.sys_cron_log IS 'Cron 执行日志视图（只读）'；
