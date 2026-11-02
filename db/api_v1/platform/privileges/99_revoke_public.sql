-- =============================================================================
-- api_v1_platform: 回收 PUBLIC EXECUTE（44 号文档 P0-3）
-- 背景: Postgres 函数默认 EXECUTE TO PUBLIC——web_anon 绕过网关 jwt-auth 直打
--       PostgREST :3100 即可调用全部 api_v1_* 函数（含全量聚合）。
-- 姿势: 登录基线=authenticated；本模块前序文件声明的「仅管理员」REVOKE 在
--       批量授权后重放，保持原收口；新增函数经 ALTER DEFAULT PRIVILEGES 兜底。
-- =============================================================================

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_platform FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api_v1_platform TO authenticated;

-- 将来新建函数：不落 PUBLIC，默认 authenticated（app_owner 所建）
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA api_v1_platform
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA api_v1_platform
    GRANT EXECUTE ON FUNCTIONS TO authenticated;

-- 登录引导函数保持 web_anon 可用（无 JWT 阶段兜底；单对象返回无放大面）
GRANT EXECUTE ON FUNCTION api_v1_platform.get_config(p_config_key text) TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.get_all_public_configs() TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.get_current_user() TO web_anon;
GRANT EXECUTE ON FUNCTION api_v1_platform.ensure_user() TO web_anon;
