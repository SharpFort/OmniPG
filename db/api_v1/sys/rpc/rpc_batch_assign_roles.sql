-- db/api_v1/sys/rpc/rpc_batch_assign_roles.sql
-- 批量分配角色给用户 RPC（带租户校验，跳过冲突）
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.batch_assign_roles(
    p_user_id uuid,
    p_role_ids uuid[]
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_tenant_id uuid;
    v_role_rec RECORD;
    v_assigned int := 0;
    v_skipped int := 0;
BEGIN
    SELECT tenant_id INTO v_user_tenant_id
    FROM public.sys_user WHERE id = p_user_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    FOR v_role_rec IN SELECT id, tenant_id, role_code FROM public.sys_role 
                      WHERE id = ANY(p_role_ids) AND deleted_at IS NULL
    LOOP
        IF v_role_rec.tenant_id IS NOT NULL AND v_role_rec.tenant_id != v_user_tenant_id THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;
        
        INSERT INTO public.sys_user_role (user_id, role_id, tenant_id)
        VALUES (p_user_id, v_role_rec.id, v_user_tenant_id)
        ON CONFLICT DO NOTHING;
        
        IF FOUND THEN
            v_assigned := v_assigned + 1;
        ELSE
            v_skipped := v_skipped + 1;
        END IF;
    END LOOP;
    
    RETURN json_build_object(
        'assigned', v_assigned,
        'skipped', v_skipped,
        'total', array_length(p_role_ids, 1)
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.batch_assign_roles(uuid, uuid[]) IS '批量分配角色给用户（带租户校验，跳过冲突）';
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_assign_roles(uuid, uuid[]) TO authenticated;
