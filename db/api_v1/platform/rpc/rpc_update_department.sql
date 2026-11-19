-- api_v1/platform/rpc/rpc_update_department.sql
-- D27: 部门更新按 organization_id + tenant_id 双维度。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_department(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_dept_name text DEFAULT NULL,
    p_sort_order int DEFAULT NULL, p_is_active boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('platform:dept:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM department
                   WHERE id = p_id AND organization_id = current_organization_id()
                     AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'dept not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    -- 新父必须存在、属于当前组织/租户且未软删除（与 create 路径同等校验，堵住 COALESCE 更新旁路）
    IF p_parent_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM department
                       WHERE id = p_parent_id
                         AND organization_id = current_organization_id()
                         AND tenant_id = current_logto_tenant_id()
                         AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'parent department not found in organization' USING ERRCODE = 'P0002';
        END IF;
        -- 防环：新父不得位于本部门子树内（深度上限防既有脏环导致递归失控）
        IF EXISTS (
            WITH RECURSIVE sub AS (
                SELECT id, 1 AS depth FROM department WHERE id = p_id
                UNION ALL
                SELECT d.id, s.depth + 1
                FROM department d JOIN sub s ON d.parent_id = s.id
                WHERE s.depth < 100
            )
            SELECT 1 FROM sub WHERE id = p_parent_id
        ) THEN
            RAISE EXCEPTION 'parent cannot be a descendant of the department' USING ERRCODE = '22023';
        END IF;
    END IF;
    UPDATE department SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        dept_name   = COALESCE(p_dept_name, dept_name),
        sort_order  = COALESCE(p_sort_order, sort_order),
        is_active   = COALESCE(p_is_active, is_active),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id AND organization_id = current_organization_id()
      AND tenant_id = current_logto_tenant_id();
    PERFORM log_operate('dept', 'update', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_department(uuid, uuid, text, int, boolean) TO authenticated;
