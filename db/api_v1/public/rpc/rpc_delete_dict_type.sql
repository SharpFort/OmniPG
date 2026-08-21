-- api_v1/public/rpc/rpc_delete_dict_type.sql
-- FUNCTION: api_v1_public.rpc_delete_dict_type（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_delete_dict_type(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_tenant text; v_name text;
BEGIN
    IF NOT has_permission('public:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id, dict_name INTO v_tenant, v_name FROM dict_type WHERE id = p_id;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    IF v_tenant IS NOT NULL AND v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 级联删除同作用域的数据项（dict_data 无 FK，手动清理）
    DELETE FROM dict_data WHERE dict_name = v_name
        AND tenant_id IS NOT DISTINCT FROM v_tenant;
    DELETE FROM dict_type WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_type', p_id::text,
                        'success', jsonb_build_object('name', v_name));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_delete_dict_type(uuid) TO authenticated;
