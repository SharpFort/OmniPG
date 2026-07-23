-- db/api_v1/sys/rpc/rpc_assign_role_to_user.sql
-- 分配角色给用户 RPC（带租户隔离校验）
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1.assign_role_to_user(
    p_user_id uuid,
    p_role_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_tenant_id uuid;
    v_role_tenant_id uuid;
    v_role_rec RECORD;
BEGIN
    SELECT tenant_id INTO v_user_tenant_id
    FROM public.sys_user WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    SELECT id, role_code, tenant_id INTO v_role_rec
    FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    IF v_role_rec.tenant_id IS NOT NULL AND v_role_rec.tenant_id != v_user_tenant_id THEN
        RAISE EXCEPTION 'Role belongs to different tenant' USING ERRCODE = 'P0005';
    END IF;
    
    INSERT INTO public.sys_user_role (user_id, role_id, tenant_id)
    VALUES (p_user_id, p_role_id, v_user_tenant_id)
    ON CONFLICT DO NOTHING;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1.assign_role_to_user(uuid, uuid) IS '分配角色给用户（带租户隔离校验）';
GRANT EXECUTE ON FUNCTION api_v1.assign_role_to_user(uuid, uuid) TO authenticated;
