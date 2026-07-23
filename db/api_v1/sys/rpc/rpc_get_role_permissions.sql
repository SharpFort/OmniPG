-- db/api_v1/sys/rpc/rpc_get_role_permissions.sql
-- 获取角色权限详情 RPC（API + 菜单列表）
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1.get_role_permissions(p_role_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role RECORD;
    v_apis json;
    v_menus json;
BEGIN
    SELECT * INTO v_role FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    SELECT COALESCE(json_agg(
        json_build_object('id', a.id, 'path', a.path, 'method', a.method, 'api_name', a.api_name) ORDER BY a.path
    ), '[]'::json) INTO v_apis
    FROM public.sys_role_api ra
    JOIN public.sys_api a ON ra.api_id = a.id
    WHERE ra.role_id = p_role_id AND a.deleted_at IS NULL;
    
    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.name, 'type', m.type, 'title', m.title) ORDER BY m.sort_order
    ), '[]'::json) INTO v_menus
    FROM public.sys_role_menu rm
    JOIN public.sys_menu m ON rm.menu_id = m.id
    WHERE rm.role_id = p_role_id AND m.deleted_at IS NULL;
    
    RETURN json_build_object(
        'role_id', v_role.id,
        'role_code', v_role.role_code,
        'role_name', v_role.role_name,
        'description', v_role.description,
        'is_active', v_role.is_active,
        'apis', v_apis,
        'menus', v_menus,
        'api_count', json_array_length(v_apis),
        'menu_count', json_array_length(v_menus)
    );
END;
$$;
COMMENT ON FUNCTION api_v1.get_role_permissions(uuid) IS '获取角色权限详情（API + 菜单列表）';
GRANT EXECUTE ON FUNCTION api_v1.get_role_permissions(uuid) TO authenticated;
