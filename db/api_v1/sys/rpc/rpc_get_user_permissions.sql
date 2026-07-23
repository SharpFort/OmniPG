-- db/api_v1/sys/rpc/rpc_get_user_permissions.sql
-- 获取当前用户的 API 权限列表 RPC
-- 来源: 20260707000014_auth_rpc_functions.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_user_permissions()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_roles jsonb;
    v_permissions jsonb;
BEGIN
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    v_roles := (current_setting('request.jwt.claims', true)::json->'roles')::jsonb;
    
    IF v_user_id IS NULL OR v_user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;
    
    -- 从 casbin_rule 视图获取该用户所有角色的 API 权限
    SELECT COALESCE(json_agg(
        json_build_object('path', v1, 'method', v2) ORDER BY v1, v2
    ), '[]'::json) INTO v_permissions
    FROM public.casbin_rule
    WHERE v0 IN (SELECT jsonb_array_elements_text(v_roles));
    
    RETURN json_build_object(
        'user_id', v_user_id::text,
        'roles', v_roles,
        'permissions', v_permissions
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_user_permissions() IS '获取当前用户的 API 权限列表（基于 Casbin 策略）';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_user_permissions() TO authenticated;
