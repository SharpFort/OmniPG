-- db/api_v1/sys/rpc/rpc_submit_role_request.sql
-- 提交角色申请 RPC（检查重复申请和已有角色）
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.submit_role_request(
    p_role_id uuid,
    p_user_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_applicant_id uuid;
    v_target_user_id uuid;
    v_role_tenant_id uuid;
    v_request_id uuid;
BEGIN
    v_applicant_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    v_target_user_id := COALESCE(p_user_id, v_applicant_id);
    
    SELECT tenant_id INTO v_role_tenant_id
    FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM public.sys_user_role_request
        WHERE user_id = v_target_user_id AND role_id = p_role_id AND status = 'pending'
    ) THEN
        RAISE EXCEPTION 'Pending request already exists' USING ERRCODE = 'P0005';
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM public.sys_user_role
        WHERE user_id = v_target_user_id AND role_id = p_role_id
    ) THEN
        RAISE EXCEPTION 'User already has this role' USING ERRCODE = 'P0005';
    END IF;
    
    INSERT INTO public.sys_user_role_request (user_id, role_id, tenant_id, applicant_id)
    VALUES (v_target_user_id, p_role_id, v_role_tenant_id, v_applicant_id)
    RETURNING id INTO v_request_id;
    
    RETURN v_request_id;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.submit_role_request(uuid, uuid) IS '提交角色申请（检查重复申请和已有角色）';
GRANT EXECUTE ON FUNCTION api_v1_sys.submit_role_request(uuid, uuid) TO authenticated;
