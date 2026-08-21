-- db/api_v1/platform/views/sys_config.sql
-- 系统配置视图（仅暴露 key/value，不暴露敏感描述）

CREATE OR REPLACE VIEW api_v1_platform.app_config AS
SELECT 
    id,
    config_key,
    config_value,
    config_type,
    is_public,
    created_at,
    updated_at
FROM platform.app_config;

COMMENT ON VIEW api_v1_platform.app_config IS '系统配置视图（公开配置，不含敏感描述）';
