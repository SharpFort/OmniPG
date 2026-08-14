-- api_v1/public/rpc/rpc_list_webhook_events.sql
-- FUNCTION: api_v1_public.rpc_list_webhook_events（17 号文档归位：迁移 046_webhook_event_log.sql 删定义段，本文件为唯一权威）
-- 回放终态: 046_webhook_event_log.sql；幂等写法（§9 模板）

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
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_webhook_events(text, int, int) TO authenticated;
