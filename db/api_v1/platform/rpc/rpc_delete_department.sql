-- api_v1/platform/rpc/rpc_delete_department.sql
-- D27: 部门删除按 organization_id + tenant_id 双维度。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_delete_department(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_deleted boolean := false;
BEGIN
    IF NOT has_permission('platform:dept:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- NULL/不存在统一报错（2026-11-19 修复）：原实现 NULL 或 0 行命中仍写审计并返回 ok:true
    IF p_id IS NULL THEN
        RAISE EXCEPTION 'dept id required' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM department
               WHERE parent_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_profile
               WHERE dept_id = p_id AND organization_id = current_organization_id()
                 AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM department WHERE id = p_id
      AND organization_id = current_organization_id() AND tenant_id = current_logto_tenant_id()
    RETURNING true INTO v_deleted;
    -- IS DISTINCT FROM（2026-11-19 修补）：PL/pgSQL 中 DELETE ... RETURNING ... INTO
    -- 影响 0 行时目标变量被赋 NULL（而非保持初值），`IF NOT v_deleted` 对 NULL 恒不触发
    IF v_deleted IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'dept not found' USING ERRCODE = 'P0002';
    END IF;
    PERFORM log_operate('dept', 'delete', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_delete_department(uuid) TO authenticated;
