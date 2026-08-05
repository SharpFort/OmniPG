-- db/api_v1/sys/views/sys_config_admin.sql
-- 系统配置管理视图（含描述，仅管理员可见）

CREATE OR REPLACE VIEW api_v1_sys.sys_config_admin AS
SELECT 
    id,
    config_key,
    config_value,
    config_type,
    description,
    is_public,
    created_at,
    updated_at
FROM public.app_config;

COMMENT ON VIEW api_v1_sys.sys_config_admin IS '系统配置管理视图（含描述，仅管理员使用）';
