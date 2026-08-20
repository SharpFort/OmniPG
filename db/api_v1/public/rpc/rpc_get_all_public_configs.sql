-- db/api_v1/public/rpc/rpc_get_all_public_configs.sql
-- 获取所有公开配置（前端初始化时调用）

CREATE OR REPLACE FUNCTION api_v1_public.get_all_public_configs()
RETURNS json
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        json_object_agg(config_key, config_value),
        '{}'::json
    )
    FROM public.app_config
    WHERE is_public = TRUE;
$$;
COMMENT ON FUNCTION api_v1_public.get_all_public_configs() IS '获取所有公开配置（前端初始化）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_all_public_configs() TO authenticated;
