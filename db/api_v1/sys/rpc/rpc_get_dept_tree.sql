-- db/api_v1/sys/rpc/rpc_get_dept_tree.sql
-- 获取部门树形结构 RPC（递归 CTE），按路径排序
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1_sys.get_dept_tree(p_tenant_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE dept_tree AS (
        SELECT 
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            1 AS level,
            ARRAY[d.id] AS path_ids,
            ARRAY[d.dept_name] AS path_names
        FROM public.sys_department d
        WHERE d.parent_id IS NULL AND d.deleted_at IS NULL
          AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)
        
        UNION ALL
        
        SELECT 
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            dt.level + 1,
            dt.path_ids || d.id,
            dt.path_names || d.dept_name
        FROM public.sys_department d
        JOIN dept_tree dt ON d.parent_id = dt.id
        WHERE d.deleted_at IS NULL AND dt.level < 10
    )
    SELECT COALESCE(json_agg(
        json_build_object(
            'id', dt.id,
            'dept_name', dt.dept_name,
            'parent_id', dt.parent_id,
            'sort_order', dt.sort_order,
            'is_active', dt.is_active,
            'level', dt.level,
            'path', array_to_string(dt.path_names, ' > ')
        ) ORDER BY dt.path_ids
    ), '[]'::json) INTO v_result
    FROM dept_tree dt;
    
    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.get_dept_tree(uuid) IS '获取部门树形结构（递归 CTE），按路径排序';
GRANT EXECUTE ON FUNCTION api_v1_sys.get_dept_tree(uuid) TO authenticated;
