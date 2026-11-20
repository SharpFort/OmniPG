-- db/api_v1/platform/views/sys_config.sql
-- 系统配置视图（仅暴露 key/value，不暴露敏感描述）
-- 2026-11-19 安全修复：补 is_public 过滤——原视图不过滤，authenticated 可读全部
-- 配置值（含 security.*/session.* 等非公开键）；管理读写走 config_admin（仅管理员）。

CREATE OR REPLACE VIEW api_v1_platform.app_config AS
SELECT 
    id,
    config_key,
    config_value,
    config_type,
    is_public,
    created_at,
    updated_at
FROM platform.app_config
WHERE is_public = TRUE
  -- 租户谓词（2026-11-19 补丁）：app_config 无 RLS，视图必须自带边界；
  -- 无 claims 会话（web_anon）→ 'default'，与 get_all_public_configs 行为一致
  AND tenant_id = current_logto_tenant_id_strict();

COMMENT ON VIEW api_v1_platform.app_config IS '系统配置视图（公开配置，is_public + 租户过滤；不含敏感描述）';
