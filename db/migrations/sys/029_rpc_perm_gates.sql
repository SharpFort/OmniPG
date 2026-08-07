-- =============================================================================
-- 029_rpc_perm_gates.sql — DEFINER 写/管理 RPC 补 has_permission 门槛
-- =============================================================================
-- 背景: 2026-08-05 用户拍板（05.4 权限校验三层模型 P-3）
--   旧 DEFINER 写/管理 RPC（绕过 RLS + 无门槛）= 任何 authenticated 可执行：
--     update_config / import_csv / export_csv / cleanup_expired_tokens
--   补齐权限点 + 入口门槛（与 024/025 新 CRUD 统一模式）
-- 权限点: sys:config:write / sys:import / sys:session:cleanup（⚠️ 035 删 sys:export——
--   export_csv 已删除，导出走 GET /view 原生能力）
--   绑定: role_super_admin（tenant_admin 不授予——配置/导入/会话清理为平台级）
-- 幂等: CREATE OR REPLACE（函数）+ ON CONFLICT（seed）；apply-src 重放安全
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 权限点 seed + 超管绑定
-- ---------------------------------------------------------------------------
INSERT INTO iam_api (api_code, path, method, name, is_active)
SELECT x.api_code, '/rpc/' || x.api_code, 'POST', x.name, true
FROM (VALUES
    ('sys:config:write',     '配置-写入'),
    ('sys:import',           '数据-导入'),
    ('sys:session:cleanup',  '会话-清理')
) AS x(api_code, name)
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id)
SELECT 'role_super_admin', id FROM iam_api
WHERE api_code IN ('sys:config:write','sys:import','sys:session:cleanup')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §1 update_config — 补 sys:config:write 门槛
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.update_config(
    p_config_key text,
    p_config_value text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT has_permission('sys:config:write') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    UPDATE public.app_config
    SET config_value = p_config_value, updated_at = now()
    WHERE config_key = p_config_key;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Config key not found: %', p_config_key USING ERRCODE = 'P0001';
    END IF;

    PERFORM log_operate('config', 'update', 'app_config', p_config_key);
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_public.update_config(text, text) IS '更新系统配置（sys:config:write；029 补门槛）';
GRANT EXECUTE ON FUNCTION api_v1_public.update_config(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §2 import_csv — 补 sys:import 门槛
-- ---------------------------------------------------------------------------
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
    v_valid_tables text[];
    v_item jsonb;
    v_inserted int := 0;
    v_errors text[] := '{}';
    v_columns text[];
    v_values text[];
    v_sql text;
BEGIN
    IF NOT has_permission('sys:import') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    -- 白名单校验
    SELECT array_agg(table_name) INTO v_valid_tables
    FROM information_schema.tables
    WHERE table_schema = 'api_v1_public'
      AND table_type IN ('VIEW', 'BASE TABLE')
      AND table_name NOT IN ('app_config', 'audit_log', 'cron_job_log');

    IF NOT (p_table_name = ANY(v_valid_tables)) THEN
        RAISE EXCEPTION 'Table % not found or not importable', p_table_name USING ERRCODE = 'P0001';
    END IF;

    -- 验证数据
    IF jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data is empty' USING ERRCODE = 'P0005';
    END IF;

    -- 遍历每条记录
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            SELECT array_agg(k), array_agg(v::text)
            INTO v_columns, v_values
            FROM jsonb_each_text(v_item) AS t(k, v);

            v_sql := format('INSERT INTO api_v1_public.%I (%s) VALUES (%s)',
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

    PERFORM log_operate('import', 'import', p_table_name, NULL::text,
                        'success', jsonb_build_object('total', jsonb_array_length(p_data),
                                                      'inserted', v_inserted));
    RETURN json_build_object(
        'table', p_table_name,
        'total', jsonb_array_length(p_data),
        'inserted', v_inserted,
        'errors', v_errors,
        'dry_run', p_dry_run
    );
END;
$$;
COMMENT ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) IS '通用导入：JSON 数组导入任意表（sys:import；029 补门槛）';
GRANT EXECUTE ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 export_csv — ⚠️ 035 已删除（半成品：返回提示文本非数据；DEFINER + 裸 SQL 拼接
--    注入面；PostgREST 不支持流式 COPY。导出 = GET /api_v1_public/{view}?select=...
--    RLS 生效 + Range 分页，前端拼 CSV。源文件 rpc_export_csv.sql 已 git rm，
--    已执行环境由 035 DROP FUNCTION IF EXISTS 兜底）
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §4 cleanup_expired_tokens — 补 sys:session:cleanup 门槛（sql → plpgsql）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.cleanup_expired_tokens()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT has_permission('sys:session:cleanup') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    PERFORM public.cleanup_expired_tokens();
END;
$$;
COMMENT ON FUNCTION api_v1_public.cleanup_expired_tokens() IS '清理过期 Token（sys:session:cleanup；029 补门槛）';
GRANT EXECUTE ON FUNCTION api_v1_public.cleanup_expired_tokens() TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_gates int; v_perms int;
BEGIN
    -- 3 个函数体均含 has_permission 门槛（035: export_csv 已删除）
    SELECT count(*) INTO v_gates FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('update_config','import_csv','cleanup_expired_tokens')
        AND prosrc LIKE '%has_permission%';
    SELECT count(*) INTO v_perms FROM iam_api
      WHERE api_code IN ('sys:config:write','sys:import','sys:session:cleanup');
    RAISE NOTICE '029: 门槛函数=%（期望3） 权限点=%（期望3）', v_gates, v_perms;
END $$;
