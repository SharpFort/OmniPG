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

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
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
        NULL;
    END;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_platform.webhook_logto(jsonb) TO web_anon;
