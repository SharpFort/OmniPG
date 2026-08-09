-- db/api_v1/public/rpc/rpc_update_config.sql
-- 更新配置（管理员）——⚠️ 035 源文件同步 029 门槛版（原源文件为无门槛旧版，
-- 029 迁移 CREATE OR REPLACE 补 sys:config:write 门槛；apply-src 重放时源文件
-- 先建旧版、029 覆盖——最终正确但源文件误导，现同步为最终版）

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
COMMENT ON FUNCTION api_v1_public.update_config(text, text) IS '更新系统配置（sys:config:write；029 补门槛，035 源文件同步）';
GRANT EXECUTE ON FUNCTION api_v1_public.update_config(text, text) TO authenticated;
