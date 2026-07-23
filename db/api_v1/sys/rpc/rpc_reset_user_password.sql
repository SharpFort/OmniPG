-- db/api_v1/sys/rpc/rpc_reset_user_password.sql
-- 重置用户密码 RPC：管理员直接设置新密码
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.reset_user_password(
    p_user_id uuid,
    p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.reset_user_password(uuid, text) IS '重置用户密码：管理员直接设置新密码';
