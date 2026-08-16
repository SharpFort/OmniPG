-- src/public/functions/current_visible_dept_ids.sql
-- FUNCTION: public.current_visible_dept_ids（17 号文档归位：迁移 042_role_data_scope.sql 删定义段，本文件为唯一权威）
-- 回放终态: 042_role_data_scope.sql；幂等写法（§9 模板）
-- 2026-08-16: LANGUAGE sql → plpgsql（sql 函数体 CREATE 时即解析绑定；本函数引用
--   current_data_scope()/current_user_dept_id()，文件序靠后，全新库单遍重放必炸）

CREATE OR REPLACE FUNCTION current_visible_dept_ids() RETURNS SETOF uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN QUERY
    WITH scope AS (
        SELECT scope_type, dept_ids
        FROM jsonb_to_record(current_data_scope()) AS x(scope_type text, dept_ids jsonb)
    )
    -- all: 全部部门
    SELECT d.id FROM department d JOIN scope s ON true WHERE s.scope_type = 'all'
    UNION
    -- custom: 指定部门
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'custom'
      AND d.id IN (SELECT (jsonb_array_elements_text(s.dept_ids))::uuid)
    UNION
    -- dept_and_child: 用户部门及其后代（无部门 → 空集）
    SELECT d.id FROM department d JOIN scope s ON true
    WHERE s.scope_type = 'dept_and_child'
      AND (d.id = current_user_dept_id() OR d.id IN (
          WITH RECURSIVE subtree AS (
              SELECT id FROM department WHERE id = current_user_dept_id()
              UNION ALL
              SELECT c.id FROM department c
              JOIN subtree p ON c.parent_id = p.id
          )
          SELECT id FROM subtree));
END;
$$;
GRANT EXECUTE ON FUNCTION current_visible_dept_ids() TO authenticated;
