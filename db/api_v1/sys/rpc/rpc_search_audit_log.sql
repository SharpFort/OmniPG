-- db/api_v1/sys/rpc/rpc_search_audit_log.sql
-- 搜索审计日志 RPC（支持关键词、表名、操作筛选）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE FUNCTION api_v1_sys.search_audit_log(
    p_query text DEFAULT NULL,
    p_table_name text DEFAULT NULL,
    p_operation text DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
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
        'total', (SELECT COUNT(*) FROM api_v1_sys.v_audit_log_detail
                  WHERE (p_table_name IS NULL OR table_name = p_table_name)
                    AND (p_operation IS NULL OR operation = p_operation)
                    AND (p_query IS NULL OR old_data::text ILIKE '%' || p_query || '%' OR new_data::text ILIKE '%' || p_query || '%')),
        'limit', p_limit,
        'offset', p_offset,
        'items', COALESCE(
            (SELECT json_agg(row_to_json(a.*) ORDER BY a.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_sys.v_audit_log_detail
                 WHERE (p_table_name IS NULL OR table_name = p_table_name)
                   AND (p_operation IS NULL OR operation = p_operation)
                   AND (p_query IS NULL OR old_data::text ILIKE '%' || p_query || '%' OR new_data::text ILIKE '%' || p_query || '%')
                 ORDER BY created_at DESC
                 LIMIT p_limit OFFSET p_offset
             ) a),
            '[]'::json
        )
    ) INTO v_result;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.search_audit_log(text, text, text, int, int) IS '搜索审计日志（支持关键词、表名、操作筛选）';
GRANT EXECUTE ON FUNCTION api_v1_sys.search_audit_log(text, text, text, int, int) TO authenticated;
