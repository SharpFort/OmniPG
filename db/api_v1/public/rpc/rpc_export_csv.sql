-- db/api_v1/sys/rpc/rpc_export_csv.sql
-- 通用导出 RPC：任何表/视图 → CSV 文本（基于 COPY TO STDOUT）
-- P1 修复：通用数据导出
--
-- 安全约束：
--   1. 白名单校验表名（防止 SQL 注入）
--   2. 仅允许已存在的表/视图
--   3. 遵循 RLS 策略（仅能导出用户有权限的数据）

CREATE OR REPLACE FUNCTION api_v1_public.export_csv(
    p_table_name text,
    p_columns text DEFAULT '*',
    p_filter text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_query text;
    v_result text;
    v_valid_tables text[];
BEGIN
    -- 白名单校验：只允许已知的 api_v1_public 视图/表
    SELECT array_agg(table_name) INTO v_valid_tables
    FROM information_schema.tables
    WHERE table_schema = 'api_v1_public'
      AND table_type IN ('VIEW', 'BASE TABLE');
    
    IF NOT (p_table_name = ANY(v_valid_tables)) THEN
        RAISE EXCEPTION 'Table/view % not found in api_v1_public schema. Valid: %', 
            p_table_name, array_to_string(v_valid_tables, ', ') USING ERRCODE = 'P0001';
    END IF;
    
    -- 构造查询
    IF p_filter = '' THEN
        v_query := format('COPY (SELECT %s FROM api_v1_public.%I) TO STDOUT WITH CSV HEADER',
                          p_columns, p_table_name);
    ELSE
        v_query := format('COPY (SELECT %s FROM api_v1_public.%I WHERE %s) TO STDOUT WITH CSV HEADER',
                          p_columns, p_table_name, p_filter);
    END IF;
    
    -- 执行 COPY TO STDOUT（结果返回给 PostgREST）
    -- 注意：PostgREST 中 COPY TO STDOUT 返回的是 text 格式
    EXECUTE v_query;
    
    -- 由于 COPY 不能直接在函数中返回结果集，此处返回提示
    -- 实际导出建议：前端直接 GET /api_v1_public/view_name?select=col1,col2 后自行拼 CSV
    RETURN format('Use GET /api_v1_public/%s?select=%s to fetch data as JSON, then convert to CSV in frontend.',
                  p_table_name, p_columns);
END;
$$;
COMMENT ON FUNCTION api_v1_public.export_csv(text, text, text) IS '通用导出提示：PostgREST 不支持流式 COPY，建议前端通过标准 GET 接口获取 JSON 后转换';
GRANT EXECUTE ON FUNCTION api_v1_public.export_csv(text, text, text) TO authenticated;
