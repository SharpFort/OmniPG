-- api_v1/public/rpc/rpc_create_dict_data.sql
-- FUNCTION: api_v1_public.rpc_create_dict_data（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_dict_data(
    p_dict_name text, p_item_label text, p_item_value text,
    p_item_type text DEFAULT 'default', p_is_default boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 字典类型必须存在，且作用域匹配当前租户（或全局超管）
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE dict_name = p_dict_name;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE dict_name = p_dict_name) THEN
            RAISE EXCEPTION 'dict type not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_data (tenant_id, dict_name, item_label, item_value,
                           item_type, is_default, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_item_label, p_item_value,
            p_item_type, p_is_default, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_data', v_id::text,
                        'success', jsonb_build_object('dict', p_dict_name, 'value', p_item_value));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_dict_data(text, text, text, text, boolean, int) TO authenticated;
