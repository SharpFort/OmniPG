-- db/api_v1/platform/rpc/rpc_get_role_permissions.sql
-- 获取角色权限 RPC（T7 重写: Logto 语义 role 镜像 + iam_role_api→iam_api + iam_role_menu→iam_menu）
-- 055 重写: 单表化后 apis 段 = 角色菜单下挂接口（role_menu → button 行 api_url 非空），
--           输出键 path/method/api_name 保持——前端授权弹窗契约不变
-- 入参: p_role_code text（Logto 角色名 = role_code）
-- 来源: 20260707000015_system_management_api.sql → T7 适配 → 055 单表化

DROP FUNCTION IF EXISTS api_v1_platform.get_role_permissions(uuid);
DROP FUNCTION IF EXISTS api_v1_platform.get_role_permissions(text);
CREATE FUNCTION api_v1_platform.get_role_permissions(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SET search_path = platform, ext, pg_temp
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

    -- 055 单表化：API 授权 = 角色绑定按钮行中带端点的行
    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'path', m.api_url, 'method', m.api_method, 'api_name', m.menu_name)
        ORDER BY m.api_url
    ), '[]'::json) INTO v_apis
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active AND m.api_url IS NOT NULL;

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
COMMENT ON FUNCTION api_v1_platform.get_role_permissions(text) IS '获取角色权限（055 单表化: apis 段 = 角色菜单下挂接口，输出键 path/method/api_name 保持）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_role_permissions(text) TO authenticated;
