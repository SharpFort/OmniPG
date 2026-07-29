-- db/api_v1/sys/rpc/rpc_change_user_password.sql
-- 修改用户密码 RPC：验证旧密码后更新（含密码策略）
-- 来源: 20260707000013_postgrest_api_v1.sql + P0 修复

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
    -- 密码策略：新密码最小长度
    IF length(p_new_password) < 8 THEN
        RAISE EXCEPTION 'Password must be at least 8 characters' USING ERRCODE = 'P0005';
    END IF;
    
    SELECT password_hash INTO v_current_hash
    FROM public.sys_user
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    IF v_current_hash IS DISTINCT FROM pwhash_crypt(p_old_password, v_current_hash) THEN
        RAISE EXCEPTION 'Invalid old password' USING ERRCODE = 'P0001';
    END IF;
    
    -- 密码策略：新密码不能与旧密码相同
    IF pwhash_crypt(p_new_password, v_current_hash) = v_current_hash THEN
        RAISE EXCEPTION 'New password must be different from old password' USING ERRCODE = 'P0005';
    END IF;
    
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.change_user_password(uuid, text, text) IS '修改用户密码：验证旧密码后更新（含密码策略：最小8位、不能复用）';
GRANT EXECUTE ON FUNCTION api_v1_sys.change_user_password(uuid, text, text) TO authenticated;
