-- db/api_v1/platform/rpc/rpc_get_menu_tree_admin.sql
-- 获取完整菜单树形结构 RPC（管理用），按层级和排序
-- T7: iam_menu（列 menu_name/order_num，无 title/component/permission_code）
-- 055: +menu_type/api_code/api_url/api_method/is_affix——管理树 + 授权弹窗数据源
-- 来源: 20260707000015_system_management_api.sql → T7 适配 → 055 单表化

CREATE OR REPLACE FUNCTION api_v1_platform.get_menu_tree_admin()
RETURNS json
LANGUAGE plpgsql
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM platform.iam_menu m
        WHERE m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM platform.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.is_active AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'menu_type', mt.menu_type, 'api_code', mt.api_code,
        'api_url', mt.api_url, 'api_method', mt.api_method, 'is_affix', mt.is_affix,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM menu_tree mt;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.get_menu_tree_admin() IS '获取完整菜单树形结构（管理用），按层级和排序（055: +menu_type/api_code/api_url/api_method/is_affix——授权弹窗数据源）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_menu_tree_admin() TO authenticated;
