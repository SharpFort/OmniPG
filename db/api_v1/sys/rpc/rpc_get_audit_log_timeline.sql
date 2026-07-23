-- db/api_v1/sys/rpc/rpc_get_audit_log_timeline.sql
-- 获取审计时间线 RPC（按天聚合）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_audit_log_timeline(
    p_start_date timestamp DEFAULT (now() - interval '7 days'),
    p_end_date timestamp DEFAULT now()
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
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
                 SELECT * FROM api_v1_sys.v_audit_log_timeline
                 WHERE log_date >= p_start_date AND log_date <= p_end_date
             ) t),
            '[]'::json
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_audit_log_timeline(timestamp, timestamp) IS '获取审计时间线（按天聚合）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_audit_log_timeline(timestamp, timestamp) TO authenticated;
