-- api_v1/platform/rpc/rpc_webhook_logto.sql
-- D25: 同库只读后仅保留 PostSignIn（登录日志）分支；镜像同步事件全部退役。
-- 数据事件（User.*/Role.*/Organization.*/OrganizationRole.*/Membership）不再需要，
-- 用户/角色/租户由 platform 内只读投影视图直读 Logto public 表。

CREATE OR REPLACE FUNCTION api_v1_platform.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_event  text := $1->>'event';
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
        WHEN 'PostSignIn' THEN
            -- 登录日志独立容错——失败仅落 error 不阻断（避免重试双写）
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
        ELSE
            IF v_log_id IS NOT NULL THEN
                UPDATE webhook_event_log SET result = 'ignored' WHERE id = v_log_id;
            END IF;
    END CASE;

    IF v_log_id IS NOT NULL AND NOT v_failed
       AND NOT EXISTS (SELECT 1 FROM webhook_event_log WHERE id = v_log_id AND result <> 'received') THEN
        UPDATE webhook_event_log SET result = 'success' WHERE id = v_log_id;
    END IF;

    -- ok 仅为"传输成功"标记（避免 Logto 端重试风暴造成双写）；
    -- degraded 标记 PostSignIn 日志写入失败，ignored 标记非登录事件未处理，
    -- 供 rpc_replay_webhook_event 区分真实处理结果（2026-11-19 修补）
    RETURN jsonb_build_object('ok', true, 'degraded', v_failed, 'ignored', v_event IS DISTINCT FROM 'PostSignIn');
EXCEPTION WHEN OTHERS THEN
    BEGIN
        -- 外层异常会回滚函数体内全部写入（含 :19 的事件行 INSERT）——v_log_id 已失效，
        -- 不能按其 UPDATE（2026-11-19 修补），必须重新插入一条 error 记录
        INSERT INTO webhook_event_log (hook_id, event, logto_created, payload, result, error)
        VALUES ($1->>'hookId', v_event, logto_ts($1->>'createdAt'), $1, 'error', SQLERRM);
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    -- SQLERRM 不再返回给调用方（web_anon，S-C22）：详细信息只入 webhook_event_log.error
    RETURN jsonb_build_object('ok', false, 'error', 'internal error');
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_platform.webhook_logto(jsonb) TO web_anon;
