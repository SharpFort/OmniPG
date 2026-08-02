-- db/src/sys/functions/current_user_dept_id.sql
-- 当前用户部门 ID（Phase 1: Casdoor JWT 无 dept claim，改查 sys_user_profile）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配
-- Phase 1 修复: SECURITY DEFINER（同 current_tenant_id，防 profile RLS 递归）

CREATE OR REPLACE FUNCTION current_user_dept_id() 
RETURNS uuid AS $$
    SELECT p.dept_id
    FROM sys_user_profile p
    WHERE p.user_id = current_user_id()
      AND p.deleted_at IS NULL
    LIMIT 1;
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = public, pg_temp;
COMMENT ON FUNCTION current_user_dept_id() IS '当前用户部门 ID（Phase 1: 从 sys_user_profile 查询；SECURITY DEFINER 防 RLS 递归）';
