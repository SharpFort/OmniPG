-- api_v1/public/rpc/rpc_update_department.sql
-- FUNCTION: api_v1_public.rpc_update_department（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_department(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_dept_name text DEFAULT NULL,
    p_sort_order int DEFAULT NULL, p_is_active boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
BEGIN
    IF NOT has_permission('public:dept:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM department
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'dept not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE department SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        dept_name   = COALESCE(p_dept_name, dept_name),
        sort_order  = COALESCE(p_sort_order, sort_order),
        is_active   = COALESCE(p_is_active, is_active),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('dept', 'update', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_department(uuid, uuid, text, int, boolean) TO authenticated;
