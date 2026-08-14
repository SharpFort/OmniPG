-- =============================================================================
-- 046_webhook_event_log.sql — N6 webhook 事件落库 + 失败可观测
-- =============================================================================
-- 背景: 33 号审查文档 §3 N6（2026-08-11 实施）——
--   原 webhook_logto EXCEPTION 分支返回 {ok:true, warn:SQLERRM}：
--   ① Logto 视作 2xx 成功 → 不重试、无告警；
--   ② 无任何事件落库/审计 → 单条同步失败（FK 不满足、类型错误等）永久丢失且无人知晓。
-- 方案（取舍说明）:
--   - 每次 webhook 调用落一行 webhook_event_log（hookId/event/createdAt/原始 payload/result/error）
--     → 同步链路全量可观测（成功/失败/忽略），payload 留存供审计与重放；
--   - 失败返回 {ok:false, error}（HTTP 200）而非 RAISE——RAISE 会让 PostgREST 返回 500
--     触发 Logto 重试，但同一事务内 event_log 的 error 更新会随事务回滚 → 失败不可观测。
--     取舍：可观测优先；丢失单次推送由两条兜底补偿——① Logto Console 手动 Replay（官方能力）
--     ② 本迁移的 rpc_replay_webhook_event（payload 已留存，sync_* 全部幂等，重放安全）。
--     （P2 可选增强：APISIX 层检测响应体 warn/ok:false 改写 503 状态码触发 Logto 自动重试）
--   - PostSignIn 登录日志分支独立容错：失败仅落 event_log=error 不阻断（登录日志容忍丢失，
--     重试反而会双写——login_log 无幂等键）；
--   - 未知事件落 ignored（Logto Console "发送测试负载"会投递匿名事件，可观测订阅缺口）。
-- 幂等: IF NOT EXISTS / CREATE OR REPLACE / DROP+CREATE+GRANT 可重放。
-- 依赖: uuidv7()（PG18 内置）、logto_ts（010）、require_super_admin/log_operate（024/035）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 webhook_event_log 表（public 底层）
--     保留周期: 90 天（与 audit_log 清理策略一致；P2 挂 pg_cron 定期清理）
--     RLS: payload 含用户 PII → 仅超管可读；webhook_logto 为 SECURITY DEFINER 写入绕过 RLS
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS webhook_event_log (
    id            uuid PRIMARY KEY DEFAULT uuidv7(),
    hook_id       text,                                   -- payload.hookId（webhook 配置标识）
    event         text NOT NULL,                          -- payload.event（User.Created / PostSignIn / ...）
    logto_created timestamptz,                            -- payload.createdAt（logto_ts 兼容毫秒/ISO）
    payload       jsonb NOT NULL,                         -- 原始 payload（审计 + 重放数据源）
    result        text NOT NULL DEFAULT 'received',       -- received / success / error / ignored
    error         text,                                   -- SQLERRM（result=error 时）
    created_at    timestamptz NOT NULL DEFAULT now()      -- 本库接收时间
);

COMMENT ON TABLE webhook_event_log IS 'Logto webhook 事件日志（N6：同步链路可观测；payload 留存供审计/重放；保留 90 天）';
COMMENT ON COLUMN webhook_event_log.result IS '处理结果：received（落库未完成）/ success / error（同步失败）/ ignored（未知事件）';

CREATE INDEX IF NOT EXISTS idx_wev_created ON webhook_event_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wev_event ON webhook_event_log(event);
CREATE INDEX IF NOT EXISTS idx_wev_result ON webhook_event_log(result);
CREATE INDEX IF NOT EXISTS idx_wev_hook ON webhook_event_log(hook_id);

GRANT SELECT ON webhook_event_log TO authenticated;

ALTER TABLE webhook_event_log ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- §2 webhook_logto 重写（N6 落库；N1 删除兜底/N25 表名修复保持）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §3 管理端 RPC（超管专属；payload 含 PII）
-- ---------------------------------------------------------------------------
-- 3.1 事件列表（result 过滤 + 分页上限 100；含 payload 供详情展示/重放入口）



-- 3.2 失败事件重放（payload 重喂 webhook_logto；sync_* 幂等；新行记录重放结果）



-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tbl int; v_fn int; v_pol int;
BEGIN
    SELECT count(*) INTO v_tbl FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'webhook_event_log';
    -- 环境自适应（17 号文档：函数已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    v_fn := (to_regprocedure('api_v1_public.rpc_list_webhook_events(text,int,int)') IS NOT NULL)::int
          + (to_regprocedure('api_v1_public.rpc_replay_webhook_event(uuid)') IS NOT NULL)::int;
    SELECT count(*) INTO v_pol FROM pg_policies WHERE tablename = 'webhook_event_log';
    RAISE NOTICE '046: 表=% 函数=% 策略=%（dbmate 阶段函数/策略=0，apply-src 后=2/1）', v_tbl, v_fn, v_pol;
    -- 环境自适应（17 号文档）：函数/策略已归位 src，dbmate up 阶段不存在
    IF v_tbl <> 1 OR NOT (v_fn IN (0, 2)) OR NOT (v_pol IN (0, 1)) THEN
        RAISE EXCEPTION '046 验证失败';
    END IF;
    RAISE NOTICE '046: 全部验证通过';
END $$;
