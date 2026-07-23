-- db/src/sys/functions/get_user_menu.sql
-- 获取当前用户的菜单树和按钮权限
-- 来源: 20260707000006_create_permission_functions.sql

CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json AS $$
DECLARE
    v_username varchar;
    v_user_id uuid;
    v_menu_tree json;
BEGIN
    v_username := current_setting('request.jwt.claims', true)::json->>'username';
    
    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;

    SELECT id INTO v_user_id FROM sys_user WHERE username = v_username AND deleted_at IS NULL;

    WITH RECURSIVE menu_cte AS (
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        WHERE ur.user_id = v_user_id AND m.parent_id IS NULL AND m.type IN ('DIR', 'MENU')
          AND m.deleted_at IS NULL
        
        UNION ALL
        
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE ur.user_id = v_user_id AND m.type IN ('DIR', 'MENU')
          AND m.deleted_at IS NULL
    )
    SELECT json_agg(row_to_json(t)) INTO v_menu_tree
    FROM (
        SELECT 
            c.id, 
            c.parent_id, 
            c.name, 
            c.path, 
            c.component, 
            json_build_object('title', c.title, 'icon', c.icon) AS meta,
            (
                SELECT COALESCE(json_agg(btn.permission_code), '[]'::json)
                FROM sys_menu btn
                JOIN sys_role_menu rmb ON btn.id = rmb.menu_id
                JOIN sys_user_role urb ON rmb.role_id = urb.role_id
                WHERE btn.parent_id = c.id 
                  AND btn.type = 'BUTTON' 
                  AND urb.user_id = v_user_id
                  AND btn.deleted_at IS NULL
            ) AS buttons
        FROM menu_cte c
        ORDER BY c.sort_order
    ) t;

    RETURN v_menu_tree;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION get_user_menu() IS '获取当前用户有权访问的菜单树（含按钮权限标识），仅返回未软删除的菜单';
