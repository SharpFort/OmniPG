-- db/api_v1/sys/rpc/rpc_update_config.sql
-- 更新配置（管理员）

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
    UPDATE public.app_config
    SET config_value = p_config_value, updated_at = now()
    WHERE config_key = p_config_key;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Config key not found: %', p_config_key USING ERRCODE = 'P0001';
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_public.update_config(text, text) IS '更新系统配置（管理员）';
GRANT EXECUTE ON FUNCTION api_v1_public.update_config(text, text) TO authenticated;
