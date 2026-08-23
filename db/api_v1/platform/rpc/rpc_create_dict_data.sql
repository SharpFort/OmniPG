-- api_v1/platform/rpc/rpc_create_dict_data.sql
-- D27: 字典数据写入 organization_id（业务组织；全局为 NULL）+ tenant_id（Logto 租户）。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_dict_data(
    p_dict_name text, p_item_label text, p_item_value text,
    p_item_type text DEFAULT 'default', p_is_default boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid; v_org text; v_global_ok boolean;
BEGIN
    IF NOT has_permission('platform:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT organization_id, (organization_id IS NULL) INTO v_org, v_global_ok
    FROM dict_type WHERE dict_name = p_dict_name AND tenant_id = current_logto_tenant_id() LIMIT 1;
    IF v_org IS NULL AND NOT v_global_ok THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE dict_name = p_dict_name) THEN
            RAISE EXCEPTION 'dict type not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_org IS NOT NULL AND v_org <> current_organization_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_data (organization_id, tenant_id, dict_name, item_label, item_value,
                           item_type, is_default, sort_no, created_by)
    VALUES (v_org, current_logto_tenant_id(), p_dict_name, p_item_label, p_item_value,
            p_item_type, p_is_default, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_data', v_id::text,
                        'success', jsonb_build_object('dict', p_dict_name, 'value', p_item_value));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_dict_data(text, text, text, text, boolean, int) TO authenticated;
