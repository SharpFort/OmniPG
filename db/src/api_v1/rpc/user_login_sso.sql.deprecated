CREATE OR REPLACE FUNCTION api_v1.user_login_sso(p_username TEXT, p_password TEXT)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.user_login_sso(p_username, p_password) $$;
COMMENT ON FUNCTION api_v1.user_login_sso(TEXT, TEXT) IS 'SSO 登录 RPC：包装 public.user_login_sso，签发双 Token';
