-- api_v1/public/rpc/rpc_get_role_data_scope.sql
-- FUNCTION: api_v1_public.rpc_get_role_data_scope（17 号文档归位：迁移 042_role_data_scope.sql 删定义段，本文件为唯一权威）
-- 回放终态: 042_role_data_scope.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_get_role_data_scope(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_scope_type text;
    v_depts      json;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT min(scope_type) INTO v_scope_type
    FROM iam_role_data_scope WHERE role_code = p_role_code;
    -- custom 可多行，取任意非 NULL 类型即该角色类型（约束保证同角色类型一致）

    SELECT COALESCE(json_agg(json_build_object('id', d.id, 'name', d.dept_name)
                             ORDER BY d.dept_name), '[]'::json) INTO v_depts
    FROM iam_role_data_scope rs
    JOIN department d ON d.id = rs.dept_id
    WHERE rs.role_code = p_role_code AND rs.dept_id IS NOT NULL;

    RETURN json_build_object(
        'role_code', p_role_code,
        'scope_type', COALESCE(v_scope_type, 'self'),
        'depts', v_depts);
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_get_role_data_scope(text) TO authenticated;
