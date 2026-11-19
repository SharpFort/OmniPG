-- api_v1/platform/rpc/rpc_replay_webhook_event.sql
-- FUNCTION: api_v1_platform.rpc_replay_webhook_event（17 号文档归位：迁移 046_webhook_event_log.sql 删定义段，本文件为唯一权威）
-- 回放终态: 046_webhook_event_log.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_replay_webhook_event(p_event_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
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

    v_res := api_v1_platform.webhook_logto(v_payload);
    -- 回放结果校验（2026-11-19 修补）：ok 仅是传输标记——degraded（日志写入失败）与
    -- ignored（非 PostSignIn 事件未处理）任一为真都不算成功回放
    IF COALESCE((v_res->>'ok')::boolean, false)
       AND NOT COALESCE((v_res->>'degraded')::boolean, false)
       AND NOT COALESCE((v_res->>'ignored')::boolean, false) THEN
        PERFORM log_operate('webhook', 'replay', 'webhook_event_log', p_event_id::text,
                            'success', jsonb_build_object('event', v_event, 'result', v_res));
        RETURN json_build_object('ok', true, 'event', v_event, 'replay', v_res);
    ELSE
        PERFORM log_operate('webhook', 'replay', 'webhook_event_log', p_event_id::text,
                            'error', jsonb_build_object('event', v_event, 'result', v_res));
        RETURN json_build_object('ok', false, 'event', v_event, 'replay', v_res);
    END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_replay_webhook_event(uuid) TO authenticated;
