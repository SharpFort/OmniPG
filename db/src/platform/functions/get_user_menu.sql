-- db/src/platform/functions/get_user_menu.sql
-- 获取用户菜单树（T7 重写：Logto JWT roles → iam_role_menu → iam_menu）
-- 来源: 20260707000006_create_permission_functions.sql → T7 适配 → 035 +menu_type → 038 +导航元字段
-- 035: 增加 menu_type/perms/is_visible 列——前端 §2.4 需按 menu_type 过滤
--      button 按钮项（033 回填的按钮项若绑定进 iam_role_menu 会混入路由注册）
-- 038: +is_link/is_iframe/keep_alive/redirect/query/route_name——前端 MenuProcessor
--      外链判改用 is_link 直判（不再靠 path LIKE http% hack），keep_alive→meta.keepAlive
-- 055: +is_affix——前端多页签布局固定标签（可选消费）
-- 056: -query——字段全空 + 前端死路由，B1 清理（与 056 迁移同批；038/044 重放会
--      用旧版覆盖，056 迁移自带重建段兜底）
-- 057: keep_alive→is_cache 输出键（SharpFort IsCache 语义 + is_ 前缀统一；
--      前端 MenuProcessor 读 is_cache → meta.keepAlive，Vue 侧 meta.keepAlive 不改；
--      038/044/056 重放会用旧版覆盖，057 迁移自带重建段兜底）

CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_roles)) THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
            m.is_affix
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
            m.is_affix
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.is_active
    )
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_menu_tree
    FROM (
        SELECT
            c.id, c.parent_id, c.name, c.path,
            c.menu_type, c.perms, c.is_visible, c.component,
            c.is_link, c.is_iframe, c.is_cache, c.redirect, c.route_name,
            c.is_affix,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（057: keep_alive→is_cache 输出键——前端 MenuProcessor 映射同步，Vue meta.keepAlive 不改；056: -query B1 清理；055: +is_affix）';
