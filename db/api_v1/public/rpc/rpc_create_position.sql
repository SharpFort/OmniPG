-- api_v1/public/rpc/rpc_create_position.sql
-- FUNCTION: api_v1_public.rpc_create_position（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_position(
    p_pos_name text, p_parent_id uuid DEFAULT NULL, p_pos_code text DEFAULT NULL,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:position:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_pos_name IS NULL OR trim(p_pos_name) = '' THEN
        RAISE EXCEPTION 'pos_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO position (tenant_id, pos_name, pos_code, parent_id, sort_no, created_by)
    VALUES (current_tenant_id(), p_pos_name, p_pos_code, p_parent_id, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('position', 'create', 'position', v_id::text,
                        'success', jsonb_build_object('name', p_pos_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_position(text, uuid, text, int) TO authenticated;
