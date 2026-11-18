-- api_v1/platform/rpc/rpc_create_position.sql
-- D27: 岗位写入 organization_id + tenant_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_position(
    p_pos_name text, p_parent_id uuid DEFAULT NULL, p_pos_code text DEFAULT NULL,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('platform:position:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_pos_name IS NULL OR trim(p_pos_name) = '' THEN
        RAISE EXCEPTION 'pos_name required' USING ERRCODE = '22023';
    END IF;
    IF current_organization_id() IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    -- 校验 parent_id 必须属于当前组织与租户且未软删除，防止跨租户孤儿节点与越权挂载
    IF p_parent_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM position
        WHERE id = p_parent_id
          AND organization_id = current_organization_id()
          AND tenant_id = current_logto_tenant_id()
          AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'parent position not found in organization' USING ERRCODE = 'P0002';
    END IF;
    INSERT INTO position (organization_id, tenant_id, pos_name, pos_code, parent_id, sort_no, created_by)
    VALUES (current_organization_id(), current_logto_tenant_id(), trim(p_pos_name), trim(p_pos_code), p_parent_id, COALESCE(p_sort_no, 0), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('position', 'create', 'position', v_id::text,
                        'success', jsonb_build_object('name', p_pos_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_position(text, uuid, text, int) TO authenticated;
