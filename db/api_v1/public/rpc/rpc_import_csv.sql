-- db/api_v1/public/rpc/rpc_import_csv.sql
-- 通用导入 RPC（035 重写：显式业务表白名单 + jsonb_populate_record 参数化）
-- 来源: 20260707000014_auth_rpc_functions.sql → T7 → 029 门槛 → 035 安全重写 → 055 白名单调整
--
-- 安全约束（035）:
--   1. 显式白名单：仅业务自主表（department/position/user_position/
--      dict_type/dict_data/iam_menu）——镜像表（users/tenants/
--      user_tenants/role/user_role）、审计/日志/绑定表一律禁止导入；
--      055 单表化：iam_api 已删除，白名单移除（端点信息并入 iam_menu）
--   2. 参数化插入：jsonb_populate_record 单行插入（类型安全、列名安全、
--      JSON null → NULL；原实现值拼接无引号 = 注入面 + null 错位）
--   3. sys:import 权限点门槛（029 seed + 绑定超管）
--   4. dry_run 预览 + per-row 错误收集 + log_operate 审计

CREATE OR REPLACE FUNCTION api_v1_public.import_csv(
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
    v_allow    text[] := ARRAY['department','position','user_position',
                               'dict_type','dict_data','iam_menu'];
    v_item     jsonb;
    v_inserted int := 0;
    v_errors   text[] := '{}';
    v_cols     text;
    v_sql      text;
BEGIN
    PERFORM require_permission('public:import');

    IF NOT (p_table_name = ANY(v_allow)) THEN
        RAISE EXCEPTION 'Table % not importable. Allowed: %',
            p_table_name, array_to_string(v_allow, ', ') USING ERRCODE = 'P0001';
    END IF;

    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'array'
       OR jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data must be a non-empty JSON array' USING ERRCODE = 'P0005';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            IF jsonb_typeof(v_item) <> 'object'
               OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_item)) THEN
                RAISE EXCEPTION 'row must be a non-empty JSON object';
            END IF;

            -- 列子集插入：仅 JSON 提供的键（quote_ident 防注入），
            -- 缺失列（id/created_at 等）走表 DEFAULT——jsonb_populate_record
            -- 全列填充会把 NULL 显式传入导致 NOT NULL 冲突（PGlite 验证发现）
            v_cols := (SELECT string_agg(quote_ident(k), ', ')
                       FROM jsonb_object_keys(v_item) AS k);
            v_sql := format('INSERT INTO api_v1_public.%I (%s) ' ||
                            'SELECT %s FROM jsonb_populate_record(NULL::api_v1_public.%I, $1)',
                            p_table_name, v_cols, v_cols, p_table_name);

            IF NOT p_dry_run THEN
                EXECUTE v_sql USING v_item;
                v_inserted := v_inserted + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_errors := array_append(v_errors, format('Row %s: %s', v_item::text, SQLERRM));
        END;
    END LOOP;

    PERFORM log_operate('import', 'import', p_table_name, NULL::text, 'success',
                        jsonb_build_object('total', jsonb_array_length(p_data),
                                           'inserted', v_inserted));
    RETURN json_build_object('table', p_table_name,
                             'total', jsonb_array_length(p_data),
                             'inserted', v_inserted,
                             'errors', v_errors,
                             'dry_run', p_dry_run);
END;
$$;
COMMENT ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) IS '通用导入（035 重写：显式业务表白名单 + jsonb_populate_record 参数化列子集；public:import）';
GRANT EXECUTE ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) TO authenticated;
