-- db/src/sys/functions/get_user_menu.sql
-- 获取用户菜单树（T7 重写：Logto JWT roles → iam_role_menu → iam_menu）
-- 来源: 20260707000006_create_permission_functions.sql → T7 适配
-- Casdoor 时代按 sys_user_role JOIN（已删表）；Logto 语义直接消费 roles claim（05 §5.3.1）

CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR jsonb_array_length(v_roles) = 0 THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon, m.order_num
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon, m.order_num
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
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（Logto：JWT roles → iam_role_menu → iam_menu）';
