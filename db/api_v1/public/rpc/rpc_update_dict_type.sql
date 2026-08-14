-- api_v1/public/rpc/rpc_update_dict_type.sql
-- FUNCTION: api_v1_public.rpc_update_dict_type（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_dict_type(
    p_id uuid, p_dict_label text DEFAULT NULL, p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('public:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_type SET
        dict_label = COALESCE(p_dict_label, dict_label),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_type', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_dict_type(uuid, text, int, boolean) TO authenticated;
