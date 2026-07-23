-- db/api_v1/sys/rpc/rpc_kick_user.sql
-- 强制踢下线 RPC：包装 public.kick_user
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1.kick_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.kick_user(p_user_id) $$;
COMMENT ON FUNCTION api_v1.kick_user(uuid) IS '强制踢下线：委托 public.kick_user';
