-- db/api_v1/platform/rpc/rpc_search_audit_log.sql
-- 搜索审计日志 RPC（关键词/表名/操作/时间范围筛选）
-- 来源: 20260707000017_audit_session_monitoring.sql → 035 LIMIT 上限统一 100 → 036 搜索增强
-- 036: p_query 同时匹配操作人(username)；p_table_name 模糊 ILIKE；新增 p_start_date/p_end_date
-- 权限档位: 无门槛（SECURITY INVOKER + RLS 超管/本租户行级隔离）
-- ⚠️ 签名 5 参 → 7 参：应用时须 DROP 旧 5 参重载（见 036 迁移），否则 PGRST203

CREATE OR REPLACE FUNCTION api_v1_platform.search_audit_log(
    p_query text DEFAULT NULL,
    p_table_name text DEFAULT NULL,
    p_operation text DEFAULT NULL,
    p_start_date timestamptz DEFAULT NULL,
    p_end_date timestamptz DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
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
        'total', (SELECT COUNT(*) FROM api_v1_platform.v_audit_log_detail
                  WHERE (p_table_name IS NULL OR table_name ILIKE '%' || p_table_name || '%')
                    AND (p_operation IS NULL OR operation = p_operation)
                    AND (p_start_date IS NULL OR created_at >= p_start_date)
                    AND (p_end_date IS NULL OR created_at <= p_end_date)
                    AND (p_query IS NULL OR username ILIKE '%' || p_query || '%'
                         OR old_data::text ILIKE '%' || p_query || '%'
                         OR new_data::text ILIKE '%' || p_query || '%')),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(a.*) ORDER BY a.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_platform.v_audit_log_detail
                 WHERE (p_table_name IS NULL OR table_name ILIKE '%' || p_table_name || '%')
                   AND (p_operation IS NULL OR operation = p_operation)
                   AND (p_start_date IS NULL OR created_at >= p_start_date)
                   AND (p_end_date IS NULL OR created_at <= p_end_date)
                   AND (p_query IS NULL OR username ILIKE '%' || p_query || '%'
                         OR old_data::text ILIKE '%' || p_query || '%'
                         OR new_data::text ILIKE '%' || p_query || '%')
                 ORDER BY created_at DESC
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) a),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.search_audit_log(text, text, text, timestamptz, timestamptz, int, int) IS
    '搜索审计日志（036: 时间范围/操作人/表名模糊；035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';
GRANT EXECUTE ON FUNCTION api_v1_platform.search_audit_log(text, text, text, timestamptz, timestamptz, int, int) TO authenticated;
