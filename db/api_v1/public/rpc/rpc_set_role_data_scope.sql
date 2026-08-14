-- api_v1/public/rpc/rpc_set_role_data_scope.sql
-- FUNCTION: api_v1_public.rpc_set_role_data_scope（17 号文档归位：迁移 042_role_data_scope.sql 删定义段，本文件为唯一权威）
-- 回放终态: 042_role_data_scope.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_set_role_data_scope(
    p_role_code text, p_scope_type text, p_dept_ids uuid[] DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_dept uuid;
BEGIN
    IF NOT has_permission('public:data-scope:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 角色校验同 041（镜像表 OR 已有绑定——镜像同步缺口兜底）
    IF p_role_code IS NULL OR NOT (
        EXISTS (SELECT 1 FROM role WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_api WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_menu WHERE role_code = p_role_code)
        OR EXISTS (SELECT 1 FROM iam_role_data_scope WHERE role_code = p_role_code)
    ) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_scope_type IS NULL OR p_scope_type NOT IN ('all','dept_and_child','self','custom') THEN
        RAISE EXCEPTION 'invalid scope_type' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type = 'custom' AND (p_dept_ids IS NULL OR cardinality(p_dept_ids) = 0) THEN
        RAISE EXCEPTION 'custom scope requires dept_ids' USING ERRCODE = '22023';
    END IF;
    IF p_scope_type <> 'custom' AND p_dept_ids IS NOT NULL AND cardinality(p_dept_ids) > 0 THEN
        RAISE EXCEPTION 'non-custom scope cannot carry dept_ids' USING ERRCODE = '22023';
    END IF;

    -- 全量覆盖（单事务）
    DELETE FROM iam_role_data_scope WHERE role_code = p_role_code;
    IF p_scope_type = 'custom' THEN
        FOREACH v_dept IN ARRAY p_dept_ids LOOP
            IF NOT EXISTS (SELECT 1 FROM department WHERE id = v_dept AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'dept not found: %', v_dept USING ERRCODE = 'P0002';
            END IF;
            INSERT INTO iam_role_data_scope (role_code, scope_type, dept_id, created_by)
            VALUES (p_role_code, 'custom', v_dept, current_user_id());
        END LOOP;
    ELSE
        INSERT INTO iam_role_data_scope (role_code, scope_type, created_by)
        VALUES (p_role_code, p_scope_type, current_user_id());
    END IF;

    PERFORM log_operate('role', 'set-data-scope', 'iam_role_data_scope',
                        p_role_code, 'success',
                        jsonb_build_object('scope_type', p_scope_type, 'dept_count', coalesce(cardinality(p_dept_ids), 0)));
    RETURN json_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_set_role_data_scope(text, text, uuid[]) TO authenticated;
