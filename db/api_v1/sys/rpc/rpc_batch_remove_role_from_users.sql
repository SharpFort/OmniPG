-- db/api_v1/sys/rpc/rpc_batch_remove_role_from_users.sql
-- 批量从多个用户移除角色 RPC（同一角色 → 多用户）
-- P0 修复：补充批量操作能力

CREATE OR REPLACE FUNCTION api_v1_sys.batch_remove_role_from_users(
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
    v_removed int;
BEGIN
    -- 验证角色存在
    SELECT id, role_code INTO v_role_rec
    FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    -- 批量删除
    DELETE FROM public.sys_user_role
    WHERE role_id = p_role_id AND user_id = ANY(p_user_ids);
    
    GET DIAGNOSTICS v_removed = ROW_COUNT;
    
    RETURN json_build_object(
        'role_id', p_role_id,
        'role_code', v_role_rec.role_code,
        'total_requested', array_length(p_user_ids, 1),
        'removed', v_removed
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.batch_remove_role_from_users(uuid, uuid[]) IS '批量从多个用户移除角色';
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_remove_role_from_users(uuid, uuid[]) TO authenticated;
