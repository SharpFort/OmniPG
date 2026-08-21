-- api_v1/public/rpc/rpc_replay_webhook_event.sql
-- FUNCTION: api_v1_public.rpc_replay_webhook_event（17 号文档归位：迁移 046_webhook_event_log.sql 删定义段，本文件为唯一权威）
-- 回放终态: 046_webhook_event_log.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_replay_webhook_event(p_event_id uuid)
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

    v_res := api_v1_public.webhook_logto(v_payload);
    PERFORM log_operate('webhook', 'replay', 'webhook_event_log', p_event_id::text,
                        'success', jsonb_build_object('event', v_event, 'result', v_res));
    RETURN json_build_object('ok', true, 'event', v_event, 'replay', v_res);
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_replay_webhook_event(uuid) TO authenticated;
