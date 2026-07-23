-- db/api_v1/sys/rpc/rpc_get_user_menu.sql
-- 获取用户菜单树 RPC：包装 public.get_user_menu
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1.get_user_menu()
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.get_user_menu() $$;
COMMENT ON FUNCTION api_v1.get_user_menu() IS '获取用户菜单树：委托 public.get_user_menu';
