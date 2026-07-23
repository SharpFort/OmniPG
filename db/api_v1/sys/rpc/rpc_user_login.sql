-- db/api_v1/sys/rpc/rpc_user_login.sql
-- 用户登录 RPC：包装 public.user_login_sso
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.user_login_sso(p_username text, p_password text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.user_login_sso(p_username, p_password) $$;
COMMENT ON FUNCTION api_v1_sys.user_login_sso(text, text) IS '用户登录：委托 public.user_login_sso';
GRANT EXECUTE ON FUNCTION api_v1_sys.user_login_sso(text, text) TO web_anon;
