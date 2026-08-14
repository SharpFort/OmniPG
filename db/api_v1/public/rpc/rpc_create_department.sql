-- api_v1/public/rpc/rpc_create_department.sql
-- FUNCTION: api_v1_public.rpc_create_department（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_department(
    p_dept_name text, p_parent_id uuid DEFAULT NULL, p_sort_order int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:dept:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dept_name IS NULL OR trim(p_dept_name) = '' THEN
        RAISE EXCEPTION 'dept_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO department (tenant_id, dept_name, parent_id, sort_order, created_by)
    VALUES (current_tenant_id(), p_dept_name, p_parent_id, p_sort_order, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dept', 'create', 'department', v_id::text,
                        'success', jsonb_build_object('name', p_dept_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_department(text, uuid, int) TO authenticated;
