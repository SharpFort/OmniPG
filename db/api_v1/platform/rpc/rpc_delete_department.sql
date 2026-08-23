-- api_v1/platform/rpc/rpc_delete_department.sql
-- D27: 部门删除按 organization_id + tenant_id 双维度。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_delete_department(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('platform:dept:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM department
               WHERE parent_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_profile
               WHERE dept_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM department WHERE id = p_id
      AND organization_id = current_organization_id() AND tenant_id = current_logto_tenant_id();
    PERFORM log_operate('dept', 'delete', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_delete_department(uuid) TO authenticated;
