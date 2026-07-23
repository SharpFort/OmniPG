-- db/api_v1/sys/rpc/rpc_cleanup_expired_tokens.sql
-- 清理过期 Token RPC：包装 public.cleanup_expired_tokens
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1.cleanup_expired_tokens()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.cleanup_expired_tokens() $$;
COMMENT ON FUNCTION api_v1.cleanup_expired_tokens() IS '清理过期 Token：委托 public.cleanup_expired_tokens';
