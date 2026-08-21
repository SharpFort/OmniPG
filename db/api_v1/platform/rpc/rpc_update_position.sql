-- api_v1/platform/rpc/rpc_update_position.sql
-- FUNCTION: api_v1_platform.rpc_update_position（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_position(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_pos_name text DEFAULT NULL,
    p_pos_code text DEFAULT NULL, p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('platform:position:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM position
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'position not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE position SET
        parent_id  = COALESCE(p_parent_id, parent_id),
        pos_name   = COALESCE(p_pos_name, pos_name),
        pos_code   = COALESCE(p_pos_code, pos_code),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'update', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_position(uuid, uuid, text, text, int, boolean) TO authenticated;
