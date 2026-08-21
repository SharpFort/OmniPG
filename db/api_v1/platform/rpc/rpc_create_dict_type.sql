-- api_v1/platform/rpc/rpc_create_dict_type.sql
-- FUNCTION: api_v1_platform.rpc_create_dict_type（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_create_dict_type(
    p_dict_name text, p_dict_label text, p_tenant_scoped boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('platform:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dict_name IS NULL OR trim(p_dict_name) = '' THEN
        RAISE EXCEPTION 'dict_name required' USING ERRCODE = '22023';
    END IF;
    v_tenant := CASE WHEN p_tenant_scoped THEN current_tenant_id() ELSE NULL END;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_type (tenant_id, dict_name, dict_label, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_dict_label, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_type', v_id::text,
                        'success', jsonb_build_object('name', p_dict_name, 'tenant_scoped', p_tenant_scoped));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_create_dict_type(text, text, boolean, int) TO authenticated;
