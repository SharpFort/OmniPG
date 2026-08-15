-- db/api_v1/sys/rpc/rpc_get_current_user.sql
-- 获取当前登录用户信息 RPC（T7: Logto 镜像语义 users+user_profile+tenants+department）
-- 来源: 20260707000014_auth_rpc_functions.sql → T7 适配
-- 061（2026-08-15）: 镜像表无 updated_at/deleted_at——updated_at 映射 logto_updated_at，
--   去 deleted_at 过滤（镜像表无软删，Logto 删除=行删除）

CREATE OR REPLACE FUNCTION api_v1_public.get_current_user()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id text;
    v_user RECORD;
BEGIN
    v_user_id := current_user_id();

    IF v_user_id IS NULL OR v_user_id = '' THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;

    SELECT u.id, u.username, u.primary_email AS email, u.primary_phone AS phone,
           p.tenant_id, p.dept_id, (NOT u.is_suspended) AS is_active,
           u.created_at, u.logto_updated_at AS updated_at,
           t.name AS tenant_name,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM public.users u
    LEFT JOIN public.user_profile p ON p.user_id = u.id
    LEFT JOIN public.tenants t ON p.tenant_id = t.id
    LEFT JOIN public.department d ON p.dept_id = d.id
    WHERE u.id = v_user_id;

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
        'dept_id', v_user.dept_id,
        'dept_name', v_user.dept_name,
        'is_active', v_user.is_active,
        'roles', v_user.roles,
        'created_at', v_user.created_at,
        'updated_at', v_user.updated_at
    );
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_current_user() IS '获取当前登录用户信息（Logto 镜像：users+user_profile+tenants）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_current_user() TO authenticated;
