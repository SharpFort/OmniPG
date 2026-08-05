-- db/src/sys/functions/current_user_dept_id.sql
-- 当前用户部门 ID（T7: 查询 user_profile，dept_id 保持 uuid）
-- 来源: 20260707000008_enable_rls_policies.sql → T7 适配

CREATE OR REPLACE FUNCTION current_user_dept_id()
RETURNS uuid AS $$
    SELECT p.dept_id
    FROM user_profile p
    WHERE p.user_id = current_user_id()
      AND p.deleted_at IS NULL
    LIMIT 1;
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = public, pg_temp;
COMMENT ON FUNCTION current_user_dept_id() IS '当前用户部门 ID（查询 user_profile；SECURITY DEFINER 防 RLS 递归）';
