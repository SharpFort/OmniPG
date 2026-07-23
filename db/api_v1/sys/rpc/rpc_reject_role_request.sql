-- db/api_v1/sys/rpc/rpc_reject_role_request.sql
-- 拒绝角色申请 RPC（不能审批自己的申请）
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.reject_role_request(p_request_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_approver_id uuid;
    v_req RECORD;
BEGIN
    v_approver_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    SELECT * INTO v_req FROM public.sys_user_role_request
    WHERE id = p_request_id AND status = 'pending' FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found or already processed' USING ERRCODE = 'P0001';
    END IF;
    
    IF v_req.applicant_id = v_approver_id THEN
        RAISE EXCEPTION 'Cannot approve your own request' USING ERRCODE = 'P0005';
    END IF;
    
    UPDATE public.sys_user_role_request
    SET status = 'rejected', approver_id = v_approver_id, approved_at = now(), updated_at = now()
    WHERE id = p_request_id;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.reject_role_request(uuid) IS '拒绝角色申请（不能审批自己的申请）';
GRANT EXECUTE ON FUNCTION api_v1_sys.reject_role_request(uuid) TO authenticated;
