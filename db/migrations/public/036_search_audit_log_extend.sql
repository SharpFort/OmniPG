-- =============================================================================
-- 036_search_audit_log_extend.sql — 审计日志搜索增强（时间范围/操作人/表名模糊）
-- =============================================================================
-- 背景: 2026-08-08 OmniAdmin 审计日志搜索重构（用户拍板；docs/搜索组件与分页跳转规范.md 配套）
--   审计日志页搜索"不合适"的根因：
--     ① 无时间范围筛选（审计检索最核心维度；v_audit_log_detail 有 created_at 未用）
--     ② p_query 只匹配 old_data/new_data 内容，搜不到操作人（username）
--     ③ p_table_name 精确匹配（=），输入 user 查不到 sys_user
--   方案（与 rpc_search_login_logs 时间约定同构，左闭右闭）:
--     p_query       → username ILIKE OR old_data::text ILIKE OR new_data::text ILIKE
--     p_table_name  → table_name ILIKE '%'||p_table_name||'%'（模糊）
--     p_operation   → 精确匹配（不变；值域 INSERT/UPDATE/DELETE/NULL=操作审计）
--     p_start_date  → created_at >= p_start_date（timestamptz）
--     p_end_date    → created_at <= p_end_date（前端日期范围补 23:59:59）
--   兼容性: 新参数全部 DEFAULT NULL，旧调用不受影响；签名 5 参 → 7 参，
--   旧 5 参重载必须 DROP（否则 PGRST203 候选函数歧义，见 027 教训）
-- =============================================================================

CREATE OR REPLACE FUNCTION api_v1_public.search_audit_log(
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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_public.v_audit_log_detail
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
                 SELECT * FROM api_v1_public.v_audit_log_detail
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

-- 旧 5 参重载删除（CREATE OR REPLACE 不同参数列表 = 新增重载，旧版残留 → PGRST203）
DROP FUNCTION IF EXISTS api_v1_public.search_audit_log(text, text, text, int, int);

COMMENT ON FUNCTION api_v1_public.search_audit_log(text, text, text, timestamptz, timestamptz, int, int) IS
    '搜索审计日志（036: 时间范围/操作人/表名模糊；035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';

GRANT EXECUTE ON FUNCTION api_v1_public.search_audit_log(text, text, text, timestamptz, timestamptz, int, int) TO authenticated;

-- =============================================================================
-- 验证块: 新签名存在 / 旧重载已删 / 权限已授
-- =============================================================================
DO $$
DECLARE
    v_new   int;
    v_old   int;
    v_grant int;
BEGIN
    SELECT count(*) INTO v_new FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'search_audit_log'
        AND pg_get_function_identity_arguments(oid) LIKE 'text, text, text, timestamp with time zone%';
    SELECT count(*) INTO v_old FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'search_audit_log'
        AND pg_get_function_identity_arguments(oid) = 'text, text, text, integer, integer';
    SELECT count(*) INTO v_grant FROM information_schema.role_routine_grants
      WHERE routine_schema = 'api_v1_public'
        AND routine_name = 'search_audit_log'
        AND grantee = 'authenticated';
    RAISE NOTICE '036: 新签名=%（期望1） 旧重载=%（期望0） authenticated授权=%（期望1）',
        v_new, v_old, v_grant;
    IF v_new <> 1 OR v_old <> 0 OR v_grant < 1 THEN
        RAISE EXCEPTION '036: 验证失败 new=% old=% grant=%', v_new, v_old, v_grant;
    END IF;
END $$;
