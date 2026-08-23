-- api_v1/platform/rpc/rpc_create_dict_type.sql
-- D27: 字典类型写入 organization_id（组织级；全局为 NULL）+ tenant_id（Logto 租户）。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_dict_type(
    p_dict_name text, p_dict_label text, p_tenant_scoped boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid; v_org text;
BEGIN
    IF NOT has_permission('platform:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dict_name IS NULL OR trim(p_dict_name) = '' THEN
        RAISE EXCEPTION 'dict_name required' USING ERRCODE = '22023';
    END IF;
    v_org := CASE WHEN p_tenant_scoped THEN current_organization_id() ELSE NULL END;
    IF v_org IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_type (organization_id, tenant_id, dict_name, dict_label, sort_no, created_by)
    VALUES (v_org, current_logto_tenant_id(), p_dict_name, p_dict_label, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_type', v_id::text,
                        'success', jsonb_build_object('name', p_dict_name, 'tenant_scoped', p_tenant_scoped));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_dict_type(text, text, boolean, int) TO authenticated;
