-- db/api_v1/sys/rpc/rpc_remove_role_from_user.sql
-- 移除用户角色 RPC
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1_sys.remove_role_from_user(
    p_user_id uuid,
    p_role_id uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    DELETE FROM public.sys_user_role 
    WHERE user_id = p_user_id AND role_id = p_role_id;
    
    SELECT TRUE;
$$;
COMMENT ON FUNCTION api_v1_sys.remove_role_from_user(uuid, uuid) IS '移除用户角色';
GRANT EXECUTE ON FUNCTION api_v1_sys.remove_role_from_user(uuid, uuid) TO authenticated;
