-- ==============================================================================
-- Migration 006: 权限管理函数（菜单树/角色审批）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. get_user_menu：获取当前用户的菜单树和按钮权限
-- ==============================================================================
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

    SELECT id INTO v_user_id FROM sys_user WHERE username = v_username;

    -- 递归查询菜单树（仅 DIR 和 MENU 类型）
    WITH RECURSIVE menu_cte AS (
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        WHERE ur.user_id = v_user_id AND m.parent_id IS NULL AND m.type IN ('DIR', 'MENU')
        
        UNION ALL
        
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE ur.user_id = v_user_id AND m.type IN ('DIR', 'MENU')
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
                -- 查询当前菜单下的按钮权限
                SELECT COALESCE(json_agg(btn.permission_code), '[]'::json)
                FROM sys_menu btn
                JOIN sys_role_menu rmb ON btn.id = rmb.menu_id
                JOIN sys_user_role urb ON rmb.role_id = urb.role_id
                WHERE btn.parent_id = c.id 
                  AND btn.type = 'BUTTON' 
                  AND urb.user_id = v_user_id
            ) AS buttons
        FROM menu_cte c
        ORDER BY c.sort_order
    ) t;

    RETURN v_menu_tree;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION get_user_menu() IS '获取当前用户有权访问的菜单树（含按钮权限标识）';

-- ==============================================================================
-- 2. sys_user_role_request：角色分配审批流表
-- ==============================================================================
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    applicant_id UUID NOT NULL,
    approver_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_user_role_request IS '角色分配审批流表';
CREATE INDEX idx_request_user ON sys_user_role_request(user_id, status);
CREATE INDEX idx_request_status ON sys_user_role_request(status);

-- ==============================================================================
-- 3. approve_role_request：审批角色申请
-- ==============================================================================
CREATE OR REPLACE FUNCTION approve_role_request(p_request_id uuid)
RETURNS boolean AS $$
DECLARE
    v_req RECORD;
    v_approver_id uuid;
BEGIN
    v_approver_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;

    SELECT * INTO v_req FROM sys_user_role_request 
    WHERE id = p_request_id AND status = 'pending' FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found or already processed' USING ERRCODE = 'P0001';
    END IF;

    UPDATE sys_user_role_request 
    SET status = 'approved', approver_id = v_approver_id, approved_at = now(), updated_at = now()
    WHERE id = p_request_id;

    INSERT INTO sys_user_role (user_id, role_id) 
    VALUES (v_req.user_id, v_req.role_id)
    ON CONFLICT DO NOTHING;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION approve_role_request(uuid) IS '审批通过角色申请：在同一事务中更新状态并写入 sys_user_role';

-- migrate:down

DROP FUNCTION IF EXISTS approve_role_request(uuid);
DROP TABLE IF EXISTS sys_user_role_request CASCADE;
DROP FUNCTION IF EXISTS get_user_menu();
