-- db/api_v1/sys/rpc/rpc_generate_user_password.sql
-- 生成 Argon2id 密码哈希 RPC
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.generate_user_password(p_password text)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.generate_user_password(p_password) $$;
COMMENT ON FUNCTION api_v1_sys.generate_user_password(text) IS '生成 Argon2id 密码哈希';
