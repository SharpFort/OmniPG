-- db/api_v1/platform/rpc/rpc_get_user_menu.sql
-- 获取用户菜单树 RPC：包装 platform.get_user_menu
-- 来源: 20260707000013_postgrest_api_v1.sql
-- 44号 P0-2 回归修正（2026-11-02）：默认上限 200→1000，与 platform.get_user_menu 同步——
--      包装层显式传参，实现层默认值不生效，两处须一起改

DROP FUNCTION IF EXISTS api_v1_platform.get_user_menu();
CREATE OR REPLACE FUNCTION api_v1_platform.get_user_menu(p_limit INTEGER DEFAULT 1000)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$ SELECT platform.get_user_menu(LEAST(COALESCE(p_limit, 1000), 2000)) $$;
COMMENT ON FUNCTION api_v1_platform.get_user_menu(INTEGER) IS '获取用户菜单树：委托 platform.get_user_menu';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_user_menu(INTEGER) TO authenticated;
