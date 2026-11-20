-- db/api_v1/platform/rpc/rpc_get_all_public_configs.sql
-- 获取所有公开配置（前端初始化时调用）

CREATE OR REPLACE FUNCTION api_v1_platform.get_all_public_configs()
RETURNS json
-- P-3g（2026-11-20，阶段 4）：标 STABLE——纯读函数原默认 VOLATILE，
-- 阻止规划器优化/内联且 PostgREST 按潜在写者对待；前端初始化热路径
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
    SELECT COALESCE(
        json_object_agg(config_key, config_value),
        '{}'::json
    )
    FROM platform.app_config
    WHERE is_public = TRUE
      -- 租户边界：公开配置仅暴露当前租户（DEFINER 绕过 RLS，须自带过滤；
      -- web_anon 无 claims → current_logto_tenant_id() = 'default'，与前端初始化契约一致）
      AND tenant_id = current_logto_tenant_id();
$$;
COMMENT ON FUNCTION api_v1_platform.get_all_public_configs() IS '获取所有公开配置（前端初始化）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_all_public_configs() TO authenticated;
