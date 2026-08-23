-- api_v1/platform/rpc/rpc_update_dict_data.sql
-- D27: 字典数据更新按 organization_id + tenant_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_dict_data(
    p_id uuid, p_item_label text DEFAULT NULL, p_item_value text DEFAULT NULL,
    p_item_type text DEFAULT NULL, p_is_default boolean DEFAULT NULL,
    p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_org text;
BEGIN
    IF NOT has_permission('platform:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT organization_id INTO v_org FROM dict_data WHERE id = p_id AND tenant_id = current_logto_tenant_id();
    IF v_org IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_org <> current_organization_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_data SET
        item_label = COALESCE(p_item_label, item_label),
        item_value = COALESCE(p_item_value, item_value),
        item_type  = COALESCE(p_item_type, item_type),
        is_default = COALESCE(p_is_default, is_default),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_dict_data(uuid, text, text, text, boolean, int, boolean) TO authenticated;
