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
DROP POLICY IF EXISTS webhook_event_log_select_policy ON webhook_event_log;
CREATE POLICY webhook_event_log_select_policy ON webhook_event_log
FOR SELECT
USING (is_super_admin());

-- ---------------------------------------------------------------------------
-- §2 webhook_logto 重写（N6 落库；N1 删除兜底/N25 表名修复保持）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_sys.webhook_logto(jsonb);
CREATE FUNCTION api_v1_sys.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_event  text := $1->>'event';
    v_data   jsonb := $1->'data';
    v_log_id uuid;
    v_failed boolean := false;
BEGIN
    -- N6: 事件落库（received；日志写入失败不阻断处理）
    BEGIN
        INSERT INTO webhook_event_log (hook_id, event, logto_created, payload)
        VALUES ($1->>'hookId', v_event, logto_ts($1->>'createdAt'), $1)
        RETURNING id INTO v_log_id;
    EXCEPTION WHEN OTHERS THEN
        v_log_id := NULL;
    END;

    CASE v_event
        -- ═══ 用户事件 ═══
        WHEN 'User.Created' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Data.Updated' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Deleted' THEN
            -- N1: data=null，删除 ID 在 params（DELETE /users/:userId → params.userId）；
            --     三键兜底：userId 优先 → id 次之 → data 最后
            PERFORM sync_user_delete(
                COALESCE($1->'params'->>'userId', $1->'params'->>'id', v_data->>'id'));

        -- ═══ 组织（租户）事件 ═══
        WHEN 'Organization.Created' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Data.Updated' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Deleted' THEN
            -- N1: DELETE /organizations/:id → params.id
            PERFORM sync_tenant_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 成员关系事件（增量 diff）═══
        WHEN 'Organization.Membership.Updated' THEN
            PERFORM sync_membership_delta(
                $1->>'organizationId',
                COALESCE($1->'addedUserIds', '[]'::jsonb),
                COALESCE($1->'removedUserIds', '[]'::jsonb));

        -- ═══ 角色目录事件 ═══
        WHEN 'Role.Created' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Data.Updated' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Deleted' THEN
            -- N1: DELETE /roles/:id → params.id
            PERFORM sync_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 登录事件（D-C：interaction payload 顶层平铺，无 data 包装）═══
        WHEN 'PostSignIn' THEN
            -- N6: 登录日志独立容错——失败仅落 error 不阻断（容忍丢失；
            --     若抛给外层重试，Logto 重发会导致 login_log 双写）
            BEGIN
                PERFORM sync_login_log_write($1);
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                IF v_log_id IS NOT NULL THEN
                    UPDATE webhook_event_log
                       SET result = 'error', error = SQLERRM
                     WHERE id = v_log_id;
                END IF;
            END;

        -- ═══ 未知事件 — 落 ignored（测试负载/未来新事件可观测）═══
        ELSE
            IF v_log_id IS NOT NULL THEN
                UPDATE webhook_event_log SET result = 'ignored' WHERE id = v_log_id;
            END IF;
    END CASE;

    -- N6: 成功落库（PostSignIn 失败/未知事件已单独标记，不覆盖）
    IF v_log_id IS NOT NULL AND NOT v_failed
       AND NOT EXISTS (SELECT 1 FROM webhook_event_log WHERE id = v_log_id AND result <> 'received') THEN
        UPDATE webhook_event_log SET result = 'success' WHERE id = v_log_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    -- N6: 失败落库（error）并返回 ok:false（HTTP 200，见文件头取舍说明）
    -- ⚠️ PL/pgSQL 语义：函数体级异常触发子事务回滚，DECLARE 变量（v_log_id/v_event）
    --    已回滚为 NULL——此处不得依赖变量，改用参数 $1（不回滚）匹配 received 行定位
    BEGIN
        UPDATE webhook_event_log
           SET result = 'error', error = SQLERRM
         WHERE id = (SELECT id FROM webhook_event_log
                     WHERE payload = $1 AND result = 'received'
                     ORDER BY created_at DESC LIMIT 1);
        IF NOT FOUND THEN
            INSERT INTO webhook_event_log (hook_id, event, logto_created, payload, result, error)
            VALUES ($1->>'hookId', $1->>'event', logto_ts($1->>'createdAt'), $1, 'error', SQLERRM);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;  -- 事件日志自身故障不再递归报错
    END;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api_v1_sys.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；N6 每次调用落 webhook_event_log（success/error/ignored）；N1 删除 ID 取 params 三键兜底；PostSignIn 失败容忍不阻断';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_logto(jsonb) TO web_anon;

-- ---------------------------------------------------------------------------
-- §3 管理端 RPC（超管专属；payload 含 PII）
-- ---------------------------------------------------------------------------
-- 3.1 事件列表（result 过滤 + 分页上限 100；含 payload 供详情展示/重放入口）
CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_webhook_events(
    p_result text DEFAULT NULL,
    p_limit  int  DEFAULT 50,
    p_offset int  DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rows  json;
    v_total int;
BEGIN
    PERFORM require_super_admin();
    IF p_result IS NOT NULL AND p_result NOT IN ('received','success','error','ignored') THEN
        RAISE EXCEPTION 'invalid result filter' USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO v_total
    FROM webhook_event_log
    WHERE p_result IS NULL OR result = p_result;

    SELECT COALESCE(json_agg(x ORDER BY x.created_at DESC), '[]'::json) INTO v_rows
    FROM (
        SELECT id, hook_id, event, logto_created, result, error, created_at, payload
        FROM webhook_event_log
        WHERE p_result IS NULL OR result = p_result
        ORDER BY created_at DESC
        LIMIT GREATEST(1, LEAST(p_limit, 100))
        OFFSET GREATEST(0, p_offset)
    ) x;

    RETURN json_build_object('total', v_total, 'rows', v_rows);
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_list_webhook_events(text, int, int) IS 'webhook 事件日志列表（超管专属；result 过滤 + 分页上限 100）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_webhook_events(text, int, int) TO authenticated;

-- 3.2 失败事件重放（payload 重喂 webhook_logto；sync_* 幂等；新行记录重放结果）
CREATE OR REPLACE FUNCTION api_v1_public.rpc_replay_webhook_event(p_event_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_payload jsonb;
    v_event   text;
    v_res     jsonb;
BEGIN
    PERFORM require_super_admin();
    SELECT payload, event INTO v_payload, v_event
    FROM webhook_event_log WHERE id = p_event_id;
    IF v_payload IS NULL THEN
        RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
    END IF;

    v_res := api_v1_sys.webhook_logto(v_payload);
    PERFORM log_operate('webhook', 'replay', 'webhook_event_log', p_event_id::text,
                        'success', jsonb_build_object('event', v_event, 'result', v_res));
    RETURN json_build_object('ok', true, 'event', v_event, 'replay', v_res);
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_replay_webhook_event(uuid) IS '重放指定 webhook 事件（超管专属；payload 重喂 webhook_logto，sync_* 幂等；重放结果新落一行）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_replay_webhook_event(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tbl int; v_fn int; v_pol int;
BEGIN
    SELECT count(*) INTO v_tbl FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'webhook_event_log';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('rpc_list_webhook_events', 'rpc_replay_webhook_event');
    SELECT count(*) INTO v_pol FROM pg_policies WHERE tablename = 'webhook_event_log';
    RAISE NOTICE '046: 表=% 函数=% 策略=%（期望 1/2/1）', v_tbl, v_fn, v_pol;
    IF v_tbl <> 1 OR v_fn <> 2 OR v_pol <> 1 THEN
        RAISE EXCEPTION '046 验证失败';
    END IF;
    RAISE NOTICE '046: 全部验证通过';
END $$;
