-- api_v1/platform/rpc/rpc_delete_position.sql
-- D27: 岗位删除按 organization_id + tenant_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_delete_position(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('platform:position:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM position
               WHERE parent_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_position
               WHERE position_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM position WHERE id = p_id
      AND organization_id = current_organization_id() AND tenant_id = current_logto_tenant_id();
    PERFORM log_operate('position', 'delete', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_delete_position(uuid) TO authenticated;
