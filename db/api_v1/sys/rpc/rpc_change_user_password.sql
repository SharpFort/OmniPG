-- db/api_v1/sys/rpc/rpc_change_user_password.sql
-- 修改用户密码 RPC：验证旧密码后更新
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.change_user_password(
    p_user_id uuid,
    p_old_password text,
    p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_current_hash text;
BEGIN
    SELECT password_hash INTO v_current_hash
    FROM public.sys_user
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    IF v_current_hash IS DISTINCT FROM pwhash_crypt(p_old_password, v_current_hash) THEN
        RAISE EXCEPTION 'Invalid old password' USING ERRCODE = 'P0001';
    END IF;
    
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.change_user_password(uuid, text, text) IS '修改用户密码：验证旧密码后更新';
