-- api_v1/platform/rpc/rpc_update_dict_data.sql
-- FUNCTION: api_v1_platform.rpc_update_dict_data（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_dict_data(
    p_id uuid, p_item_label text DEFAULT NULL, p_item_value text DEFAULT NULL,
    p_item_type text DEFAULT NULL, p_is_default boolean DEFAULT NULL,
    p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('platform:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_data WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
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
