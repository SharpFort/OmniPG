-- api_v1/public/rpc/rpc_delete_menu.sql
-- FUNCTION: api_v1_public.rpc_delete_menu（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_delete_menu(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('public:menu:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM iam_menu WHERE parent_id = p_id) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM iam_role_menu WHERE menu_id = p_id;
    DELETE FROM iam_menu WHERE id = p_id;
    PERFORM log_operate('menu', 'delete', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_delete_menu(uuid) TO authenticated;
