-- db/api_v1/platform/rpc/rpc_get_current_user.sql
-- D27: 当前用户信息输出 tenant_id（Logto 租户）与 organization_id（业务组织）。

CREATE OR REPLACE FUNCTION api_v1_platform.get_current_user()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
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
           u.tenant_id, p.organization_id, p.dept_id, (NOT u.is_suspended) AS is_active,
           u.created_at, u.updated_at,
           t.name AS tenant_name, o.name AS organization_name,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM platform.users u
    LEFT JOIN platform.user_profile p ON p.user_id = u.id
    LEFT JOIN platform.tenants t ON u.tenant_id = t.id
    LEFT JOIN platform.organizations o ON p.organization_id = o.id
    LEFT JOIN platform.department d ON p.dept_id = d.id
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
        'organization_id', v_user.organization_id,
        'organization_name', v_user.organization_name,
        'dept_id', v_user.dept_id,
        'dept_name', v_user.dept_name,
        'is_active', v_user.is_active,
        'roles', v_user.roles,
        'created_at', v_user.created_at,
        'updated_at', v_user.updated_at
    );
END;
$$;
COMMENT ON FUNCTION api_v1_platform.get_current_user() IS '获取当前登录用户信息（D27：tenant_id/organization_id 双列）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_current_user() TO authenticated;
