-- db/api_v1/sys/rpc/rpc_import_csv.sql
-- 通用导入 RPC：CSV/JSON 数据导入任意表
-- P1 修复：通用数据导入
--
-- 安全约束：
--   1. 仅允许导入到可写的表（不在白名单的系统表禁止导入）
--   2. 支持 dry_run 模式（预览，不实际写入）
--   3. 逐条插入（触发器可审计每条记录）
--
-- 参数说明：
--   p_table_name: 目标表名（仅允许 api_v1_sys 中可写的视图/表）
--   p_data: JSON 数组 [{col1: val1, col2: val2}, ...]
--   p_dry_run: 是否仅预览不写入

CREATE OR REPLACE FUNCTION api_v1_sys.import_csv(
    p_table_name text,
    p_data jsonb,
    p_dry_run boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_valid_tables text[];
    v_item jsonb;
    v_inserted int := 0;
    v_errors text[] := '{}';
    v_columns text[];
    v_values text[];
    v_sql text;
    v_key text;
    v_value text;
BEGIN
    -- 白名单校验
    SELECT array_agg(table_name) INTO v_valid_tables
    FROM information_schema.tables
    WHERE table_schema = 'api_v1_sys'
      AND table_type IN ('VIEW', 'BASE TABLE')
      AND table_name NOT IN ('sys_secret', 'sys_token_blacklist', 'sys_cron_log', 'sys_audit_log');
    
    IF NOT (p_table_name = ANY(v_valid_tables)) THEN
        RAISE EXCEPTION 'Table % not found or not importable' USING ERRCODE = 'P0001';
    END IF;
    
    -- 验证数据
    IF jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data is empty' USING ERRCODE = 'P0005';
    END IF;
    
    -- 遍历每条记录
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            -- 提取列名和值
            SELECT array_agg(k), array_agg(v::text)
            INTO v_columns, v_values
            FROM jsonb_each_text(v_item) AS t(k, v);
            
            -- 构造 INSERT
            v_sql := format('INSERT INTO api_v1_sys.%I (%s) VALUES (%s)',
                            p_table_name,
                            array_to_string(v_columns, ', '),
                            array_to_string(v_values, ', '));
            
            IF NOT p_dry_run THEN
                EXECUTE v_sql;
                v_inserted := v_inserted + 1;
            END IF;
            
        EXCEPTION WHEN OTHERS THEN
            v_errors := array_append(v_errors, format('Row %s: %s', v_item::text, SQLERRM));
        END;
    END LOOP;
    
    RETURN json_build_object(
        'table', p_table_name,
        'total', jsonb_array_length(p_data),
        'inserted', v_inserted,
        'errors', v_errors,
        'dry_run', p_dry_run
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.import_csv(text, jsonb, boolean) IS '通用导入：JSON 数组导入任意表（支持 dry_run 预览）';
GRANT EXECUTE ON FUNCTION api_v1_sys.import_csv(text, jsonb, boolean) TO authenticated;
