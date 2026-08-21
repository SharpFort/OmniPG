-- api_v1/public/rpc/rpc_delete_dict_data.sql
-- FUNCTION: api_v1_public.rpc_delete_dict_data（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_delete_dict_data(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:delete') THEN
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
    DELETE FROM dict_data WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_delete_dict_data(uuid) TO authenticated;
