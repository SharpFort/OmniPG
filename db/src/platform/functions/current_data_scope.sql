-- src/platform/functions/current_data_scope.sql
-- FUNCTION: platform.current_data_scope（17 号文档归位：迁移 042_role_data_scope.sql 删定义段，本文件为唯一权威）
-- 回放终态: 042_role_data_scope.sql；幂等写法（§9 模板）
-- D26: iam_role_data_scope 改 role_id/org_role_id 双列 FK，JWT 角色名先解析为 Logto 角色标识。

CREATE OR REPLACE FUNCTION current_data_scope() RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_roles text[];
    v_role_ids text[];
    v_org_role_ids text[];
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

    -- D26: 角色名 → Logto 角色标识
    SELECT ARRAY(SELECT r.id FROM platform.role r
                 WHERE r.name = ANY(v_roles)) INTO v_role_ids;
    SELECT ARRAY(SELECT tr.id FROM platform.tenant_role tr
                 WHERE tr.name = ANY(v_roles)) INTO v_org_role_ids;

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
    WHERE (role_id = ANY(v_role_ids) OR org_role_id = ANY(v_org_role_ids))
      AND tenant_id = current_logto_tenant_id();

    IF v_scope IS NULL THEN
        RETURN jsonb_build_object('scope_type', 'self', 'dept_ids', '[]'::jsonb);
    END IF;
    RETURN v_scope;
END;
$$;
GRANT EXECUTE ON FUNCTION current_data_scope() TO authenticated;
