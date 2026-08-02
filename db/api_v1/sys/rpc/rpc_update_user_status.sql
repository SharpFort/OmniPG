-- db/api_v1/sys/rpc/rpc_update_user_status.sql
-- 更新用户状态 RPC（Phase 1 适配: 写 casdoor_user_mirror 原始状态字段，
-- 触发器派生 is_active/deleted_at;变更会经 Database Syncer 双向同步回 Casdoor）
-- 语义映射（D6）: activate → isforbidden='false'
--                deactivate → isforbidden='true'
--                soft_delete → isdeleted='true'
--                restore → isdeleted='false'

CREATE OR REPLACE FUNCTION api_v1_sys.update_user_status(
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
    v_current_user_id := current_user_id();

    IF p_user_id = v_current_user_id AND p_action IN ('deactivate', 'soft_delete') THEN
        RAISE EXCEPTION 'Cannot deactivate or delete yourself' USING ERRCODE = 'P0005';
    END IF;

    CASE p_action
        WHEN 'activate' THEN
            UPDATE casdoor_user_mirror SET isforbidden = 'false' WHERE id = p_user_id;
        WHEN 'deactivate' THEN
            UPDATE casdoor_user_mirror SET isforbidden = 'true' WHERE id = p_user_id;
        WHEN 'soft_delete' THEN
            UPDATE casdoor_user_mirror SET isdeleted = 'true' WHERE id = p_user_id;
        WHEN 'restore' THEN
            UPDATE casdoor_user_mirror SET isdeleted = 'false' WHERE id = p_user_id;
        ELSE
            RAISE EXCEPTION 'Invalid action: %. Valid: activate, deactivate, soft_delete, restore', p_action USING ERRCODE = 'P0006';
    END CASE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;

    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.update_user_status(uuid, text) IS '更新用户状态（Phase 1: 写 mirror 原始字段，D6 触发器派生）';
GRANT EXECUTE ON FUNCTION api_v1_sys.update_user_status(uuid, text) TO authenticated;
