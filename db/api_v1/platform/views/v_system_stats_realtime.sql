-- db/api_v1/platform/views/v_system_stats_realtime.sql
-- T9: 移除已删 sys_user_session/sys_token_blacklist 引用（D12：会话/吊销交 Logto）
--     在线会话数/黑名单数无 DB 来源 → 置 NULL（列保留，前端兼容）
-- 来源: 20260707000017_audit_session_monitoring.sql（T9 改造）

DROP VIEW IF EXISTS api_v1_platform.v_system_stats_realtime CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.v_system_stats_realtime AS
SELECT
    NULL::bigint AS online_users,          -- D12: 会话管理交 Logto，无 DB 来源
    NULL::bigint AS blacklisted_tokens,    -- D12: 吊销交 Logto，无 DB 黑名单
    (SELECT MAX(execution_time) FROM platform.cron_job_log WHERE job_name = 'cleanup-old-audit-logs') AS last_cleanup_time,  -- 035: cleanup-expired-tokens 任务已删（死链），改指审计日志清理任务
    -- 计数谓词（2026-11-22 上游安全修复）：原子查询经 owner 链（BYPASSRLS）统计的是
    -- 全租户审计事件量；对齐 audit_log_read_policy 口径（超管 OR 本租户+本组织）
    (SELECT COUNT(*) FROM platform.audit_log
      WHERE created_at > now() - interval '24 hours'
        AND (is_super_admin()
             OR (tenant_id = current_logto_tenant_id_strict()
                 AND organization_id = current_organization_id()))) AS audit_24h,
    now() AS stats_time;
COMMENT ON VIEW api_v1_platform.v_system_stats_realtime IS '实时系统统计视图（T9: 会话/黑名单计数置 NULL，Logto 接管；035: last_cleanup_time 改指 cleanup-old-audit-logs；2026-11-22: audit_24h 计数谓词化+授权收归管理员）';