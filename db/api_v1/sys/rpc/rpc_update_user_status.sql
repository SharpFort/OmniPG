-- db/api_v1/sys/rpc/rpc_update_user_status.sql
-- 更新用户状态 RPC：activate/deactivate/soft_delete/restore
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1.update_user_status(
    p_user_id uuid,
    p_action text  -- 'activate', 'deactivate', 'soft_delete', 'restore'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_current_user_id uuid;
BEGIN
    v_current_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    IF p_user_id = v_current_user_id AND p_action IN ('deactivate', 'soft_delete') THEN
        RAISE EXCEPTION 'Cannot deactivate or delete yourself' USING ERRCODE = 'P0005';
    END IF;
    
    CASE p_action
        WHEN 'activate' THEN
            UPDATE public.sys_user SET is_active = TRUE, updated_at = now() WHERE id = p_user_id;
        WHEN 'deactivate' THEN
            UPDATE public.sys_user SET is_active = FALSE, updated_at = now() WHERE id = p_user_id;
        WHEN 'soft_delete' THEN
            UPDATE public.sys_user SET deleted_at = now(), updated_at = now() WHERE id = p_user_id;
        WHEN 'restore' THEN
            UPDATE public.sys_user SET deleted_at = NULL, updated_at = now() WHERE id = p_user_id;
        ELSE
            RAISE EXCEPTION 'Invalid action: %. Valid: activate, deactivate, soft_delete, restore' USING ERRCODE = 'P0006';
    END CASE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1.update_user_status(uuid, text) IS '更新用户状态：activate/deactivate/soft_delete/restore';
GRANT EXECUTE ON FUNCTION api_v1.update_user_status(uuid, text) TO authenticated;
