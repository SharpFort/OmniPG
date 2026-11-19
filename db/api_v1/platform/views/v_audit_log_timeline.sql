-- db/api_v1/platform/views/v_audit_log_timeline.sql
-- 审计时间线（按天聚合）
-- 来源: 20260707000017_audit_session_monitoring.sql
-- 2026-11-19: +security_invoker——行级边界由 platform.audit_log 的 RLS 提供

CREATE OR REPLACE VIEW api_v1_platform.v_audit_log_timeline WITH (security_invoker = true) AS
SELECT 
    DATE_TRUNC('day', created_at) AS log_date,
    table_name,
    operation,
    COUNT(*) AS change_count,
    COUNT(DISTINCT user_id) AS unique_users
FROM platform.audit_log
GROUP BY DATE_TRUNC('day', created_at), table_name, operation
ORDER BY log_date DESC, change_count DESC;
-- 兜底：CREATE OR REPLACE 对已存在视图的 reloptions 不保证覆盖，显式 SET 确保幂等生效
ALTER VIEW api_v1_platform.v_audit_log_timeline SET (security_invoker = true);
COMMENT ON VIEW api_v1_platform.v_audit_log_timeline IS '审计时间线（按天聚合）';
