-- db/src/public/functions/current_user_dept_id.sql
-- 当前用户部门 ID（T7: 查询 user_profile，dept_id 保持 uuid）
-- 来源: 20260707000008_enable_rls_policies.sql → T7 适配
-- 2026-08-16: LANGUAGE sql → plpgsql（sql 函数体 CREATE 时即解析绑定；本函数引用
--   current_user_id()，其文件名排序靠后，全新库 apply-src 单遍重放必炸）

CREATE OR REPLACE FUNCTION current_user_dept_id()
RETURNS uuid AS $$
BEGIN
    RETURN (
        SELECT p.dept_id
        FROM user_profile p
        WHERE p.user_id = current_user_id()
          AND p.deleted_at IS NULL
        LIMIT 1
    );
END;
$$ LANGUAGE plpgsql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = public, pg_temp;
COMMENT ON FUNCTION current_user_dept_id() IS '当前用户部门 ID（查询 user_profile；SECURITY DEFINER 防 RLS 递归）';
