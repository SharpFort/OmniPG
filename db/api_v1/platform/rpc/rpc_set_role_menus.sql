-- api_v1/platform/rpc/rpc_set_role_menus.sql
-- FUNCTION: api_v1_platform.rpc_set_role_menus（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）
-- D26: 落库改 role_id/org_role_id（FK 指向 Logto 基表）；入参保持 p_role_code 兼容前端。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_set_role_menus(p_role_code text, p_menu_ids uuid[])
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_role_id text;
    v_org_role_id text;
BEGIN
    IF NOT has_permission('platform:role-menu:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT r.role_id, r.org_role_id INTO v_role_id, v_org_role_id
    FROM platform.resolve_role_ident(p_role_code) r;
    IF v_role_id IS NULL AND v_org_role_id IS NULL THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM iam_role_menu
    WHERE role_id IS NOT DISTINCT FROM v_role_id
      AND org_role_id IS NOT DISTINCT FROM v_org_role_id;
    IF p_menu_ids IS NOT NULL THEN
        INSERT INTO iam_role_menu (role_id, org_role_id, menu_id, created_by)
        SELECT v_role_id, v_org_role_id, g, current_user_id()
        FROM unnest(p_menu_ids) AS g
        ON CONFLICT (role_id, org_role_id, menu_id) DO NOTHING;
    END IF;
    PERFORM log_operate('role', 'bind-menus', 'role', p_role_code,
                        'success', jsonb_build_object('menu_ids', p_menu_ids));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_set_role_menus(text, uuid[]) TO authenticated;
