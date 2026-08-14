-- api_v1/public/rpc/rpc_delete_position.sql
-- FUNCTION: api_v1_public.rpc_delete_position（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_delete_position(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('public:position:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM position
               WHERE parent_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_position
               WHERE position_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM position WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'delete', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_delete_position(uuid) TO authenticated;
