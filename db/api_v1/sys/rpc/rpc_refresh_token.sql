-- db/api_v1/sys/rpc/rpc_refresh_token.sql
-- 刷新 Token RPC：包装 public.refresh_token_rtr
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.refresh_token_rtr(p_old_rt text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.refresh_token_rtr(p_old_rt) $$;
COMMENT ON FUNCTION api_v1_sys.refresh_token_rtr(text) IS '刷新 Token：委托 public.refresh_token_rtr';
