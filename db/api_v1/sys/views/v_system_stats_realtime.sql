-- db/api_v1/sys/views/v_system_stats_realtime.sql
-- 实时系统统计视图
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE VIEW api_v1_sys.v_system_stats_realtime AS
SELECT 
    (SELECT COUNT(*) FROM public.sys_user_session WHERE is_used = FALSE AND expired_at > now()) AS online_users,
    (SELECT COUNT(*) FROM public.sys_token_blacklist WHERE expired_at > now()) AS blacklisted_tokens,
    (SELECT COUNT(*) FROM public.sys_user_role_request WHERE status = 'pending') AS pending_requests,
    (SELECT MAX(execution_time) FROM public.sys_cron_log WHERE job_name = 'cleanup-expired-tokens') AS last_cleanup_time,
    (SELECT COUNT(*) FROM public.sys_audit_log WHERE created_at > now() - interval '24 hours') AS audit_24h,
    now() AS stats_time;
COMMENT ON VIEW api_v1_sys.v_system_stats_realtime IS '实时系统统计视图';
