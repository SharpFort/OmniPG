-- api_v1/public/rpc/rpc_set_role_menus.sql
-- FUNCTION: api_v1_public.rpc_set_role_menus（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_set_role_menus(p_role_code text, p_menu_ids uuid[])
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('public:role-menu:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_role_code IS NULL OR NOT EXISTS (SELECT 1 FROM role WHERE name = p_role_code) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM iam_role_menu WHERE role_code = p_role_code;
    IF p_menu_ids IS NOT NULL THEN
        INSERT INTO iam_role_menu (role_code, menu_id, created_by)
        SELECT p_role_code, g, current_user_id()
        FROM unnest(p_menu_ids) AS g
        ON CONFLICT (role_code, menu_id) DO NOTHING;
    END IF;
    PERFORM log_operate('role', 'bind-menus', 'role', p_role_code,
                        'success', jsonb_build_object('menu_ids', p_menu_ids));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_set_role_menus(text, uuid[]) TO authenticated;
