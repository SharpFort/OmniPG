-- db/api_v1/sys/rpc/rpc_logout.sql
-- 用户登出 RPC：将当前 JWT 的 jti 加入黑名单
-- 来源: 20260707000014_auth_rpc_functions.sql

CREATE OR REPLACE FUNCTION api_v1_sys.logout()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_jti varchar;
    v_user_id uuid;
    v_exp integer;
BEGIN
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    IF v_jti IS NULL THEN
        RAISE EXCEPTION 'No token found' USING ERRCODE = 'P0001';
    END IF;
    
    v_exp := (current_setting('request.jwt.claims', true)::json->>'exp')::integer;
    
    INSERT INTO public.sys_token_blacklist (jti, expired_at, reason, user_id)
    VALUES (v_jti, to_timestamp(v_exp), 'logout', v_user_id)
    ON CONFLICT (jti) DO NOTHING;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.logout() IS '用户登出：将当前 JWT 的 jti 加入黑名单';
GRANT EXECUTE ON FUNCTION api_v1_sys.logout() TO authenticated;
