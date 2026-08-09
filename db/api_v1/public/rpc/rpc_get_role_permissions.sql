-- db/api_v1/sys/rpc/rpc_get_role_permissions.sql
-- 获取角色权限 RPC（T7 重写: Logto 语义 role 镜像 + iam_role_api→iam_api + iam_role_menu→iam_menu）
-- 入参: p_role_code text（Logto 角色名 = role_code）
-- 来源: 20260707000015_system_management_api.sql → T7 适配

DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(uuid);
DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(text);
CREATE FUNCTION api_v1_public.get_role_permissions(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role RECORD;
    v_apis json;
    v_menus json;
BEGIN
    SELECT id, name AS role_name, role_code, type, is_default INTO v_role
    FROM role WHERE role_code = p_role_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(json_agg(
        json_build_object('id', a.id, 'path', a.path, 'method', a.method, 'api_name', a.name)
        ORDER BY a.path
    ), '[]'::json) INTO v_apis
    FROM iam_role_api ra
    JOIN iam_api a ON ra.api_id = a.id
    WHERE ra.role_code = p_role_code AND a.is_active;

    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.menu_name, 'parent_id', m.parent_id,
                          'path', m.router, 'icon', m.icon)
        ORDER BY m.order_num
    ), '[]'::json) INTO v_menus
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active;

    RETURN json_build_object(
        'role_id', v_role.id,
        'role_code', v_role.role_code,
        'role_name', v_role.role_name,
        'type', v_role.type,
        'apis', v_apis,
        'menus', v_menus,
        'api_count', json_array_length(v_apis),
        'menu_count', json_array_length(v_menus)
    );
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.get_role_permissions(text) TO authenticated;
