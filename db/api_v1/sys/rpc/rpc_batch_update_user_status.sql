-- db/api_v1/sys/rpc/rpc_batch_update_user_status.sql
-- 批量更新用户状态 RPC：同时禁用/软删除/恢复多个用户
-- P0 修复：补充批量操作能力

CREATE OR REPLACE FUNCTION api_v1_sys.batch_update_user_status(
    p_user_ids uuid[],
    p_action text  -- 'activate', 'deactivate', 'soft_delete', 'restore'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_current_user_id uuid;
    v_affected int := 0;
    v_self_excluded int := 0;
    v_user_id uuid;
BEGIN
    v_current_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    -- 验证 action 参数
    IF p_action NOT IN ('activate', 'deactivate', 'soft_delete', 'restore') THEN
        RAISE EXCEPTION 'Invalid action: %. Valid: activate, deactivate, soft_delete, restore' USING ERRCODE = 'P0006';
    END IF;
    
    -- 遍历用户列表，跳过自己（防止自禁用）
    FOREACH v_user_id IN ARRAY p_user_ids
    LOOP
        IF v_user_id = v_current_user_id AND p_action IN ('deactivate', 'soft_delete') THEN
            v_self_excluded := v_self_excluded + 1;
            CONTINUE;
        END IF;
        
        CASE p_action
            WHEN 'activate' THEN
                UPDATE public.sys_user SET is_active = TRUE, updated_at = now() 
                WHERE id = v_user_id AND deleted_at IS NULL;
            WHEN 'deactivate' THEN
                UPDATE public.sys_user SET is_active = FALSE, updated_at = now() 
                WHERE id = v_user_id AND deleted_at IS NULL;
            WHEN 'soft_delete' THEN
                UPDATE public.sys_user SET deleted_at = now(), updated_at = now() 
                WHERE id = v_user_id AND deleted_at IS NULL;
            WHEN 'restore' THEN
                UPDATE public.sys_user SET deleted_at = NULL, updated_at = now() 
                WHERE id = v_user_id AND deleted_at IS NOT NULL;
        END CASE;
        
        IF FOUND THEN
            v_affected := v_affected + 1;
        END IF;
    END LOOP;
    
    RETURN json_build_object(
        'action', p_action,
        'total_requested', array_length(p_user_ids, 1),
        'affected', v_affected,
        'self_excluded', v_self_excluded
    );
END;
$$;
COMMENT ON FUNCTION api_v1_sys.batch_update_user_status(uuid[], text) IS '批量更新用户状态：activate/deactivate/soft_delete/restore（自动跳过自己）';
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_update_user_status(uuid[], text) TO authenticated;
