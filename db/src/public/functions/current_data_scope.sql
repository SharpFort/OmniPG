-- src/public/functions/current_data_scope.sql
-- FUNCTION: public.current_data_scope（17 号文档归位：迁移 042_role_data_scope.sql 删定义段，本文件为唯一权威）
-- 回放终态: 042_role_data_scope.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION current_data_scope() RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles text[];
    v_scope jsonb;
BEGIN
    -- 超管短路
    IF is_super_admin() THEN
        RETURN jsonb_build_object('scope_type', 'all', 'dept_ids', '[]'::jsonb);
    END IF;

    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;

    -- 多角色取最宽: all > dept_and_child > custom > self（RuoYi 同语义）
    SELECT jsonb_build_object(
        'scope_type', CASE
            WHEN bool_or(scope_type = 'all')           THEN 'all'
            WHEN bool_or(scope_type = 'dept_and_child') THEN 'dept_and_child'
            WHEN bool_or(scope_type = 'custom')         THEN 'custom'
            ELSE 'self' END,
        'dept_ids', COALESCE(jsonb_agg(dept_id) FILTER (WHERE dept_id IS NOT NULL), '[]'::jsonb)
    ) INTO v_scope
    FROM iam_role_data_scope
    WHERE role_code = ANY(v_roles);

    IF v_scope IS NULL THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;
    RETURN v_scope;
END;
$$;
GRANT EXECUTE ON FUNCTION current_data_scope() TO authenticated;
