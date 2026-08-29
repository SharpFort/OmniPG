-- 073_audit_timeline_null_defaults.sql
-- 073（2026-08-30）：修复审计时间线 RPC 传 NULL 日期时恒返回空
-- 背景：get_audit_log_timeline 的 p_start_date/p_end_date 原默认值为
--   now()-7 天 / now()，但 PostgreSQL 显式传 NULL 不会触发参数默认值；
--   前端不传日期时发送的是 NULL → WHERE log_date >= NULL 恒假 → 时间线恒为空。
-- 内容：参数改 DEFAULT NULL + 函数体内 COALESCE 回退最近 7 天（语义不变）。
-- migrate:up

CREATE OR REPLACE FUNCTION api_v1_platform.get_audit_log_timeline(
    p_start_date timestamp DEFAULT NULL,
    p_end_date timestamp DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
    v_start timestamp := COALESCE(p_start_date, now() - interval '7 days');
    v_end timestamp := COALESCE(p_end_date, now());
BEGIN
    SELECT json_build_object(
        'start_date', v_start,
        'end_date', v_end,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(t.*) ORDER BY t.log_date DESC)
             FROM (
                 SELECT * FROM api_v1_platform.v_audit_log_timeline
                 WHERE log_date >= v_start AND log_date <= v_end
             ) t),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.get_audit_log_timeline(timestamp, timestamp) IS '获取审计时间线（按天聚合；073: 传 NULL 回退最近 7 天）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_audit_log_timeline(timestamp, timestamp) TO authenticated;

-- migrate:down

CREATE OR REPLACE FUNCTION api_v1_platform.get_audit_log_timeline(
    p_start_date timestamp DEFAULT (now() - interval '7 days'),
    p_end_date timestamp DEFAULT now()
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'start_date', p_start_date,
        'end_date', p_end_date,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(t.*) ORDER BY t.log_date DESC)
             FROM (
                 SELECT * FROM api_v1_platform.v_audit_log_timeline
                 WHERE log_date >= p_start_date AND log_date <= p_end_date
             ) t),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
