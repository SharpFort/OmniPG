-- api_v1/platform/rpc/rpc_create_department.sql
-- D27: 部门写入 organization_id（业务组织）+ tenant_id（Logto 租户）。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_department(
    p_dept_name text, p_parent_id uuid DEFAULT NULL, p_sort_order int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('platform:dept:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dept_name IS NULL OR trim(p_dept_name) = '' THEN
        RAISE EXCEPTION 'dept_name required' USING ERRCODE = '22023';
    END IF;
    IF current_organization_id() IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO department (organization_id, tenant_id, dept_name, parent_id, sort_order, created_by)
    VALUES (current_organization_id(), current_logto_tenant_id(), p_dept_name, p_parent_id, p_sort_order, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dept', 'create', 'department', v_id::text,
                        'success', jsonb_build_object('name', p_dept_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_department(text, uuid, int) TO authenticated;
