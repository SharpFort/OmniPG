-- db/api_v1/sys/rpc/rpc_get_menu_tree_admin.sql
-- 获取完整菜单树形结构 RPC（管理用），按层级和排序
-- T7: iam_menu（列 menu_name/order_num，无 title/component/permission_code）
-- 来源: 20260707000015_system_management_api.sql → T7 适配

CREATE OR REPLACE FUNCTION api_v1_public.get_menu_tree_admin()
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM public.iam_menu m
        WHERE m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM public.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.is_active AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM menu_tree mt;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_menu_tree_admin() IS '获取完整菜单树形结构（管理用），按层级和排序';
GRANT EXECUTE ON FUNCTION api_v1_public.get_menu_tree_admin() TO authenticated;
