-- db/src/sys/functions/current_tenant_id.sql
-- 当前租户 ID（Phase 1: Casdoor JWT 无 tenant claim，改查 sys_user_profile）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配
-- Phase 1 修复: SECURITY DEFINER（避免 profile RLS 递归——profile 的 policy
--               USING 引用本函数，若本函数以调用者权限查 profile 会无限递归；
--               本函数仅查当前用户自己的档案，definer 权限无越权风险）

CREATE OR REPLACE FUNCTION current_tenant_id() 
RETURNS uuid AS $$
    SELECT p.tenant_id
    FROM sys_user_profile p
    WHERE p.user_id = current_user_id()
      AND p.deleted_at IS NULL
    LIMIT 1;
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = public, pg_temp;
COMMENT ON FUNCTION current_tenant_id() IS '当前租户 ID（Phase 1: 从 sys_user_profile 查询，D5 默认租户；SECURITY DEFINER 防 RLS 递归）';
