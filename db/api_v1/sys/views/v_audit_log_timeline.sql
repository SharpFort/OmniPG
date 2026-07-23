-- db/api_v1/sys/views/v_audit_log_timeline.sql
-- 审计时间线（按天聚合）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE VIEW api_v1_sys.v_audit_log_timeline AS
SELECT 
    DATE_TRUNC('day', created_at) AS log_date,
    table_name,
    operation,
    COUNT(*) AS change_count,
    COUNT(DISTINCT user_id) AS unique_users
FROM public.sys_audit_log
GROUP BY DATE_TRUNC('day', created_at), table_name, operation
ORDER BY log_date DESC, change_count DESC;
COMMENT ON VIEW api_v1_sys.v_audit_log_timeline IS '审计时间线（按天聚合）';
