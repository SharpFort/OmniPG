-- db/api_v1/platform/rpc/rpc_get_dept_tree.sql
-- D27: 部门树 API 参数改为 p_organization_id（业务组织）；tenant_id 取当前 Logto 租户。

DROP FUNCTION IF EXISTS api_v1_platform.get_dept_tree(text);
CREATE OR REPLACE FUNCTION api_v1_platform.get_dept_tree(p_organization_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
    v_org text := COALESCE(p_organization_id, current_organization_id());
BEGIN
    WITH RECURSIVE dept_tree AS (
        SELECT
            d.id, d.dept_name, d.tenant_id, d.organization_id, d.parent_id, d.sort_order, d.is_active,
            1 AS level,
            ARRAY[d.id] AS path_ids,
            ARRAY[d.dept_name::text] AS path_names
        FROM platform.department d
        WHERE d.parent_id IS NULL AND d.deleted_at IS NULL
          AND (p_organization_id IS NULL OR d.organization_id = p_organization_id)
          AND d.tenant_id = current_logto_tenant_id()

        UNION ALL

        SELECT
            d.id, d.dept_name, d.tenant_id, d.organization_id, d.parent_id, d.sort_order, d.is_active,
            dt.level + 1,
            dt.path_ids || d.id,
            dt.path_names || d.dept_name::text
        FROM platform.department d
        JOIN dept_tree dt ON d.parent_id = dt.id
        WHERE d.deleted_at IS NULL AND dt.level < 10
          AND d.organization_id = dt.organization_id AND d.tenant_id = dt.tenant_id
    )
    SELECT COALESCE(json_agg(
        json_build_object(
            'id', dt.id,
            'dept_name', dt.dept_name,
            'tenant_id', dt.tenant_id,
            'organization_id', dt.organization_id,
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
COMMENT ON FUNCTION api_v1_platform.get_dept_tree(text) IS '获取部门树形结构（D27：p_organization_id 传入业务组织，tenant_id 取当前 Logto 租户）';
GRANT EXECUTE ON FUNCTION api_v1_platform.get_dept_tree(text) TO authenticated;
