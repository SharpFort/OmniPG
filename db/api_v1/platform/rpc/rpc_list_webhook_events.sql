-- api_v1/platform/rpc/rpc_list_webhook_events.sql
-- FUNCTION: api_v1_platform.rpc_list_webhook_events（17 号文档归位：迁移 046_webhook_event_log.sql 删定义段，本文件为唯一权威）
-- 回放终态: 046_webhook_event_log.sql；幂等写法（§9 模板）

-- P-3j（2026-11-20）签名演进 (text,int,int) → (text,int,int,boolean)：DROP 旧签名防并存
DROP FUNCTION IF EXISTS api_v1_platform.rpc_list_webhook_events(text, int, int);
CREATE OR REPLACE FUNCTION api_v1_platform.rpc_list_webhook_events(
    p_result text DEFAULT NULL,
    p_limit  int  DEFAULT 50,
    p_offset int  DEFAULT 0,
    -- P-3j（2026-11-20，阶段 4）：列表默认不携带 payload jsonb（可含大 PII，
    -- ≤100 行/页放大响应与 json_agg 成本）；需要时显式传 true（详情抽屉等场景）。
    -- 列保留、值为 NULL——前端结构契约不变。
    p_include_payload boolean DEFAULT false
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_rows  json;
    v_total int;
BEGIN
    PERFORM require_super_admin();
    IF p_result IS NOT NULL AND p_result NOT IN ('received','success','error','ignored') THEN
        RAISE EXCEPTION 'invalid result filter' USING ERRCODE = '22023';
    END IF;
    -- P-3a（2026-11-20，阶段 4）：谓词分支化——原 `p_result IS NULL OR
    -- result = p_result` 两分支皆非 sargable（OR 阻止 result 索引使用，
    -- count + items 双扫描恒全表）；按参数分支后过滤分支可走索引
    IF p_result IS NULL THEN
        SELECT count(*) INTO v_total FROM webhook_event_log;
        SELECT COALESCE(json_agg(x ORDER BY x.created_at DESC), '[]'::json) INTO v_rows
        FROM (
            SELECT id, hook_id, event, logto_created, result, error, created_at,
                   CASE WHEN p_include_payload THEN payload ELSE NULL END AS payload
            FROM webhook_event_log
            ORDER BY created_at DESC
            LIMIT GREATEST(1, LEAST(p_limit, 100))
            OFFSET GREATEST(0, p_offset)
        ) x;
    ELSE
        SELECT count(*) INTO v_total
        FROM webhook_event_log
        WHERE result = p_result;
        SELECT COALESCE(json_agg(x ORDER BY x.created_at DESC), '[]'::json) INTO v_rows
        FROM (
            SELECT id, hook_id, event, logto_created, result, error, created_at,
                   CASE WHEN p_include_payload THEN payload ELSE NULL END AS payload
            FROM webhook_event_log
            WHERE result = p_result
            ORDER BY created_at DESC
            LIMIT GREATEST(1, LEAST(p_limit, 100))
            OFFSET GREATEST(0, p_offset)
        ) x;
    END IF;

    RETURN json_build_object('total', v_total, 'rows', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_list_webhook_events(text, int, int, boolean) TO authenticated;
