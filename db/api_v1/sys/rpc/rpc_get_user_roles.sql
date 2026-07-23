-- db/api_v1/sys/rpc/rpc_get_user_roles.sql
-- 获取用户的全部角色 RPC
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_user_roles(p_user_id uuid)
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
            'role_id', r.id,
            'role_code', r.role_code,
            'role_name', r.role_name,
            'description', r.description,
            'is_active', r.is_active,
            'tenant_id', r.tenant_id
        ) ORDER BY r.role_code
    ), '[]'::json) INTO v_result
    FROM public.sys_user_role ur
    JOIN public.sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = p_user_id AND r.deleted_at IS NULL;
    
    RETURN json_build_object('user_id', p_user_id, 'roles', v_result, 'count',
        COALESCE(json_array_length(v_result), 0));
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_user_roles(uuid) IS '获取用户的全部角色';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_user_roles(uuid) TO authenticated;
