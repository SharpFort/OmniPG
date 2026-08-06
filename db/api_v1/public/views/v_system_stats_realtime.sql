-- db/api_v1/sys/views/v_system_stats_realtime
-- T7: 移除已删 sys_user_role_request 的 pending 计数（与 013 迁移一致）
-- 来源: 20260707000017_audit_session_monitoring.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_public.v_system_stats_realtime CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_system_stats_realtime AS
SELECT
    (SELECT COUNT(*) FROM public.sys_user_session WHERE is_used = FALSE AND expired_at > now()) AS online_users,
    (SELECT COUNT(*) FROM public.sys_token_blacklist WHERE expired_at > now()) AS blacklisted_tokens,
    (SELECT MAX(execution_time) FROM public.cron_job_log WHERE job_name = 'cleanup-expired-tokens') AS last_cleanup_time,
    (SELECT COUNT(*) FROM public.audit_log WHERE created_at > now() - interval '24 hours') AS audit_24h,
    now() AS stats_time;
COMMENT ON VIEW api_v1_public.v_system_stats_realtime IS '实时系统统计视图（T7: 移除角色申请计数）';
