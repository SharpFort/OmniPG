-- api_v1/platform/rpc/rpc_delete_dict_type.sql
-- D27: 字典类型删除按 organization_id + tenant_id；级联删除同作用域数据项。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_delete_dict_type(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_org text; v_name text;
BEGIN
    IF NOT has_permission('platform:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT organization_id, dict_name INTO v_org, v_name
    FROM dict_type WHERE id = p_id AND tenant_id = current_logto_tenant_id();
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_org IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    IF v_org IS NOT NULL AND v_org <> current_organization_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    DELETE FROM dict_data WHERE dict_name = v_name
        AND tenant_id = current_logto_tenant_id()
        AND organization_id IS NOT DISTINCT FROM v_org;
    DELETE FROM dict_type WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_type', p_id::text,
                        'success', jsonb_build_object('name', v_name));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_delete_dict_type(uuid) TO authenticated;
