-- api_v1/platform/rpc/rpc_create_dict_data.sql
-- D27: 字典数据写入 organization_id（业务组织；全局为 NULL）+ tenant_id（Logto 租户）。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_dict_data(
    p_dict_name text, p_item_label text, p_item_value text,
    p_item_type text DEFAULT 'default', p_is_default boolean DEFAULT false,
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
    IF p_item_label IS NULL OR trim(p_item_label) = '' THEN
        RAISE EXCEPTION 'item_label required' USING ERRCODE = '22023';
    END IF;
    IF p_item_value IS NULL OR trim(p_item_value) = '' THEN
        RAISE EXCEPTION 'item_value required' USING ERRCODE = '22023';
    END IF;

    -- 查找当前租户下匹配的字典类型（优先匹配本组织，回退全局）
    SELECT organization_id INTO v_org
    FROM dict_type
    WHERE dict_name = p_dict_name
      AND tenant_id = current_logto_tenant_id()
      AND (organization_id IS NULL OR organization_id = current_organization_id())
    ORDER BY organization_id NULLS LAST
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'dict type not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_org IS NULL THEN
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_org IS DISTINCT FROM current_organization_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    INSERT INTO dict_data (organization_id, tenant_id, dict_name, item_label, item_value,
                           item_type, is_default, sort_no, created_by)
    VALUES (v_org, current_logto_tenant_id(), p_dict_name, trim(p_item_label), trim(p_item_value),
            COALESCE(p_item_type, 'default'), COALESCE(p_is_default, false), COALESCE(p_sort_no, 0), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_data', v_id::text,
                        'success', jsonb_build_object('dict', p_dict_name, 'value', p_item_value));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_dict_data(text, text, text, text, boolean, int) TO authenticated;
