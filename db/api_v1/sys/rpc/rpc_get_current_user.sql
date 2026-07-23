-- db/api_v1/sys/rpc/rpc_get_current_user.sql
-- 获取当前登录用户信息 RPC
-- 来源: 20260707000014_auth_rpc_functions.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_current_user()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_user RECORD;
BEGIN
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    IF v_user_id IS NULL OR v_user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;
    
    SELECT u.id, u.username, u.email, u.phone, u.tenant_id, u.dept_id, u.is_active,
           u.created_at, u.updated_at,
           t.tenant_name, t.tenant_code,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM public.sys_user u
    LEFT JOIN public.sys_tenant t ON u.tenant_id = t.id
    LEFT JOIN public.sys_department d ON u.dept_id = d.id
    WHERE u.id = v_user_id AND u.deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN json_build_object(
        'id', v_user.id,
        'username', v_user.username,
        'email', v_user.email,
        'phone', v_user.phone,
        'tenant_id', v_user.tenant_id,
        'tenant_name', v_user.tenant_name,
        'tenant_code', v_user.tenant_code,
        'dept_id', v_user.dept_id,
        'dept_name', v_user.dept_name,
        'is_active', v_user.is_active,
        'roles', v_user.roles,
        'created_at', v_user.created_at,
        'updated_at', v_user.updated_at
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_current_user() IS '获取当前登录用户信息（从 JWT claims 提取）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_current_user() TO authenticated;
