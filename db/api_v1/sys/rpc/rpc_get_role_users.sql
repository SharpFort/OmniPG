-- db/api_v1/sys/rpc/rpc_get_role_users.sql
-- 获取角色的全部用户 RPC
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_role_users(p_role_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT COALESCE(json_agg(
        json_build_object(
            'user_id', u.id,
            'username', u.username,
            'email', u.email,
            'is_active', u.is_active,
            'dept_id', u.dept_id
        ) ORDER BY u.username
    ), '[]'::json) INTO v_result
    FROM public.sys_user_role ur
    JOIN public.sys_user u ON ur.user_id = u.id
    WHERE ur.role_id = p_role_id AND u.deleted_at IS NULL;
    
    RETURN json_build_object('role_id', p_role_id, 'users', v_result, 'count',
        COALESCE(json_array_length(v_result), 0));
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_role_users(uuid) IS '获取角色的全部用户';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_role_users(uuid) TO authenticated;
