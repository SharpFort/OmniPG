-- db/api_v1/platform/rpc/rpc_get_user_menu.sql
-- 获取用户菜单树 RPC：包装 platform.get_user_menu
-- 来源: 20260707000013_postgrest_api_v1.sql

DROP FUNCTION IF EXISTS api_v1_platform.get_user_menu();
CREATE OR REPLACE FUNCTION api_v1_platform.get_user_menu(p_limit INTEGER DEFAULT 200)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$ SELECT platform.get_user_menu(LEAST(COALESCE(p_limit, 200), 2000)) $$;
COMMENT ON FUNCTION api_v1_platform.get_user_menu(INTEGER) IS '获取用户菜单树：委托 platform.get_user_menu';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_user_menu(INTEGER) TO authenticated;
