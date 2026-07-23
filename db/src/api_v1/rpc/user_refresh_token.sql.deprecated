CREATE OR REPLACE FUNCTION api_v1.user_refresh_token(p_old_rt TEXT)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.refresh_token_rtr(p_old_rt) $$;
COMMENT ON FUNCTION api_v1.user_refresh_token(TEXT) IS 'Token 刷新 RPC：包装 public.refresh_token_rtr，轮转 Refresh Token';
