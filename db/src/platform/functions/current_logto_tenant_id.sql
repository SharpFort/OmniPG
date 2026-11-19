-- db/src/platform/functions/current_logto_tenant_id.sql
-- D27：当前 Logto 部署租户 ID
-- 优先读 request.jwt.claims->>'tenant_id'（需 init-logto.py Custom Claims 注入）；
-- 未注入时回退 'default'（当前业务默认 Logto Tenant）。
-- TODO：Logto customizer 可注入 tenant_id claim 后，此处即支持 default/admin 双租户运行时路由。
-- 安全语义（2026-11-19 审查修复）：
--   * current_logto_tenant_id()        —— 兼容函数：无 claim 回退 'default'（历史行为，避免
--     claims 注入完成前 dev 链路全断；RLS 谓词继续使用它保持现状）。
--   * current_logto_tenant_id_strict() —— 严格函数：无/空 claim 返回 NULL。RLS/查询中
--     `tenant_id = strict()` 对 NULL 自然不命中（fail-closed），安全敏感 RPC 与跨租户
--     旁路判断应使用 strict 版本，杜绝"缺 claim == default 租户"的隐性越权。
--   * 两函数仅读取会话 GUC，不访问任何表：SECURITY INVOKER + search_path 仅 pg_catalog，
--     消除不必要的 DEFINER 提权面并允许规划器内联。
-- 采纳路线：strict 版本暂为"可用未接线"——dev 会话尚无 tenant_id claim（init-logto TODO），
-- 全面切换会把所有无 claim 会话判为无租户（deny），需与 claims 注入（阶段 3）同批切换；
-- 先接线审计归因（write_audit_log 已用 strict 优先），其余 RLS/谓词在 claims 注入后切换。

CREATE OR REPLACE FUNCTION current_logto_tenant_id()
RETURNS text AS $$
    SELECT COALESCE(
        NULLIF(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'tenant_id', ''),
        'default'
    )
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp;
COMMENT ON FUNCTION current_logto_tenant_id() IS '当前 Logto 部署租户 ID（兼容版：优先 claims tenant_id，无 claim 回退 default；安全敏感路径请改用 current_logto_tenant_id_strict()）';

CREATE OR REPLACE FUNCTION current_logto_tenant_id_strict()
RETURNS text AS $$
    SELECT NULLIF(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb->>'tenant_id', '')
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp;
COMMENT ON FUNCTION current_logto_tenant_id_strict() IS '严格版租户 ID：无/空 tenant_id claim 返回 NULL（fail-closed）。RLS 中 tenant_id = strict() 对 NULL 不命中，安全敏感 RPC 与旁路判断必须使用本函数';
