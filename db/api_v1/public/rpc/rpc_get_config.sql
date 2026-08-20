-- db/api_v1/public/rpc/rpc_get_config.sql
-- 获取单个配置（公开配置，前端可调用）

CREATE OR REPLACE FUNCTION api_v1_public.get_config(p_config_key text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'config_key', config_key,
        'config_value', config_value,
        'config_type', config_type
    ) INTO v_result
    FROM public.app_config
    WHERE config_key = p_config_key AND is_public = TRUE;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_config(text) IS '获取单个公开配置';
GRANT EXECUTE ON FUNCTION api_v1_public.get_config(text) TO authenticated;
