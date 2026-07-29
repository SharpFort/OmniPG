-- db/api_v1/sys/rpc/rpc_batch_assign_role_to_users.sql
-- 批量分配角色给多个用户 RPC（同一角色 → 多用户）
-- P0 修复：补充批量操作能力

CREATE OR REPLACE FUNCTION api_v1_sys.batch_assign_role_to_users(
    p_role_id uuid,
    p_user_ids uuid[]
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role_rec RECORD;
    v_user_rec RECORD;
    v_assigned int := 0;
    v_skipped int := 0;
BEGIN
    -- 验证角色存在
    SELECT id, role_code, tenant_id INTO v_role_rec
    FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    -- 遍历用户列表
    FOR v_user_rec IN 
        SELECT id, tenant_id FROM public.sys_user 
        WHERE id = ANY(p_user_ids) AND deleted_at IS NULL
    LOOP
        -- 租户校验
        IF v_role_rec.tenant_id IS NOT NULL AND v_role_rec.tenant_id != v_user_rec.tenant_id THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;
        
        INSERT INTO public.sys_user_role (user_id, role_id, tenant_id)
        VALUES (v_user_rec.id, p_role_id, v_user_rec.tenant_id)
        ON CONFLICT DO NOTHING;
        
        IF FOUND THEN
            v_assigned := v_assigned + 1;
        ELSE
            v_skipped := v_skipped + 1;
        END IF;
    END LOOP;
    
    RETURN json_build_object(
        'role_id', p_role_id,
        'role_code', v_role_rec.role_code,
        'total_requested', array_length(p_user_ids, 1),
        'assigned', v_assigned,
        'skipped', v_skipped
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.batch_assign_role_to_users(uuid, uuid[]) IS '批量分配角色给多个用户（带租户校验）';
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_assign_role_to_users(uuid, uuid[]) TO authenticated;
