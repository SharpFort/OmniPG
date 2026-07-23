-- ==============================================================================
-- Migration 010: pg_cron 定时清理任务
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 创建通用的 cron 任务记录表（用于审计）
-- ==============================================================================
CREATE TABLE IF NOT EXISTS sys_cron_log (
    id BIGSERIAL PRIMARY KEY,
    job_name VARCHAR(100) NOT NULL,
    execution_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    result JSONB,
    duration_ms INT
);
COMMENT ON TABLE sys_cron_log IS 'pg_cron 任务执行日志';

-- ==============================================================================
-- 注册清理任务：每小时清理过期的 Token 黑名单和会话
-- cron 语法：分钟 小时 日 月 星期
-- ==============================================================================
SELECT cron.schedule(
    'cleanup-expired-tokens',         -- 任务名称
    '0 * * * *',                      -- 每小时整点执行
    $$ SELECT api_v1.cleanup_expired_tokens() $$
);

-- 可选：每天凌晨 3 点清理审计日志（保留 90 天）
SELECT cron.schedule(
    'cleanup-old-audit-logs',
    '0 3 * * *',
    $$ DELETE FROM sys_audit_log WHERE created_at < now() - interval '90 days' $$
);

-- migrate:down
-- 使用参数化方式删除
DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-expired-tokens');
    PERFORM cron.unschedule('cleanup-old-audit-logs');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时忽略
END
$$;
