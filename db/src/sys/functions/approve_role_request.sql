-- db/src/sys/functions/approve_role_request.sql
-- 审批通过角色申请：在同一事务中更新状态并写入 sys_user_role
-- 来源: 20260707000006_create_permission_functions.sql

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

    INSERT INTO sys_user_role (user_id, role_id, tenant_id) 
    VALUES (v_req.user_id, v_req.role_id, v_req.tenant_id)
    ON CONFLICT DO NOTHING;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION approve_role_request(uuid) IS '审批通过角色申请：在同一事务中更新状态并写入 sys_user_role';
