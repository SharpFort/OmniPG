-- db/api_v1/platform/rpc/rpc_get_menu_tree_admin.sql
-- 获取完整菜单树形结构 RPC（管理用），按层级和排序
-- T7: iam_menu（列 menu_name/order_num，无 title/component/permission_code）
-- 055: +menu_type/api_code/api_url/api_method/is_affix——管理树 + 授权弹窗数据源
-- 来源: 20260707000015_system_management_api.sql → T7 适配 → 055 单表化

DROP FUNCTION IF EXISTS api_v1_platform.get_menu_tree_admin();
-- 2026-11-19：+has_permission 鉴权门（原任意 authenticated 可拉管理树）；
-- SECURITY DEFINER + 显式租户过滤——菜单管理员需要看到停用菜单（menu_read_policy
-- 对非超管仅放行 is_active 行，INVOKER 下管理树永远缺停用项），
-- 行级边界由本函数自带鉴权与租户谓词保证。
CREATE OR REPLACE FUNCTION api_v1_platform.get_menu_tree_admin(p_limit INTEGER DEFAULT 500)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    -- 鉴权：消费方 = 菜单管理页（menu:update/create/delete 任一）与角色-菜单绑定弹窗
    -- （role-menu:bind）；超管在 has_permission 内短路放行。
    -- TODO(075+ 迁移)：种子补 platform:menu:list 按钮权限码后收敛为单一判断，
    -- 届时同时覆盖纯只读消费者（wiki RPC 清单标注的 menu:query 语义）。
    IF NOT has_permission('platform:menu:update')
       AND NOT has_permission('platform:menu:create')
       AND NOT has_permission('platform:menu:delete')
       AND NOT has_permission('platform:role-menu:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM platform.iam_menu m
        WHERE m.parent_id IS NULL
          AND m.tenant_id = current_logto_tenant_id()

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code, m.api_url, m.api_method, m.is_affix,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM platform.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.tenant_id = current_logto_tenant_id() AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'menu_type', mt.menu_type, 'api_code', mt.api_code,
        'api_url', mt.api_url, 'api_method', mt.api_method, 'is_affix', mt.is_affix,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM (SELECT * FROM menu_tree LIMIT LEAST(COALESCE(p_limit, 500), 5000)) mt;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.get_menu_tree_admin(INTEGER) IS '获取完整菜单树形结构（管理用），按层级和排序（055: +menu_type/api_code/api_url/api_method/is_affix——授权弹窗数据源）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_menu_tree_admin(INTEGER) TO authenticated;
