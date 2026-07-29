-- db/api_v1/sys/rpc/rpc_reset_user_password.sql
-- 重置用户密码 RPC：管理员直接设置新密码（含密码策略）
-- 来源: 20260707000013_postgrest_api_v1.sql + P0 修复

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
    -- 密码策略：新密码最小长度
    IF length(p_new_password) < 8 THEN
        RAISE EXCEPTION 'Password must be at least 8 characters' USING ERRCODE = 'P0005';
    END IF;
    
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.reset_user_password(uuid, text) IS '重置用户密码：管理员直接设置新密码（含密码策略：最小8位）';
GRANT EXECUTE ON FUNCTION api_v1_sys.reset_user_password(uuid, text) TO authenticated;
