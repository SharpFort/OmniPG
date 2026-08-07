-- =============================================================================
-- 034_frontend_alignment_fixes.sql — 前端对齐方案 §1.1 视图层修复
-- =============================================================================
-- 背景: 2026-08-07 前端对齐后端方案审查（§1.1 视图清单逐视图核对源码）
--   P1-1: v_role_list.users_count 恒 0（024 建 user_role 分配镜像表后未同步）→ 真实计数
--   P1-2: dict_type/dict_data/v_dict_list 未 GRANT authenticated → 补齐
--         （login_log 有意不授——租户管理员走 rpc_search_login_logs；
--           v_user_roles/v_role_users 有意不授——user_role 表 RLS=超管OR本人，
--           租户管理员数据残缺，仅超管可用，超管已有 ALL TABLES 授权）
--   P2-1: role 视图 is_active = NOT is_default 与注释意图相反（默认角色被标停用）
--         → Logto 角色无停用状态（删除即移除），恒 true
--   P2-2: api_v1_public.user_role 视图（T7: user_tenants 投影）与
--         public.user_role 表（024: 用户↔角色分配镜像）同名不同物
--         → 视图按 026 定稿规则「视图名=底层表名」更名 user_tenants
--   P1-4: pg_cron 任务引用失效路径
--         （cleanup-expired-tokens → api_v1.cleanup_expired_tokens() 已删，
--           015 删除、029 新建 api_v1_public 版；
--           cleanup-old-audit-logs → sys_audit_log 表已更名 audit_log）→ 重调度
-- 联动: 027 双 schema 分支缺陷（DROP CASCADE 摧毁 023-026 迁移层对象）已在
--       027 文件修复（搬迁替代）；本迁移的视图定义与源文件
--       （views/role.sql、views/v_role_list.sql、views/user_tenants.sql）逐字一致
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 role 视图重建（is_active 恒 true）——与 views/role.sql 一致
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.role CASCADE;
CREATE OR REPLACE VIEW api_v1_public.role AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text                          AS tenant_id,      -- Logto 角色为全局（组织角色在 organization_roles）
    NULL::text                          AS description,
    true::boolean                       AS is_active,      -- 034: Logto 角色目录无停用状态，恒 true
    r.created_at,
    r.updated_at,
    NULL::timestamptz                   AS deleted_at,
    NULL::text                          AS created_by,
    NULL::text                          AS updated_by,
    NULL::text                          AS deleted_by
FROM role r;
COMMENT ON VIEW api_v1_public.role IS '角色表视图（Logto 镜像：role 投影，全局角色；is_active 恒 true——Logto 无角色停用概念，034）';

-- ---------------------------------------------------------------------------
-- §2 v_role_list 重建（users_count 真实计数）——与 views/v_role_list.sql 一致
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.v_role_list CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_list AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    true::boolean AS is_active,         -- 034: 同 role 视图语义
    r.created_at,
    r.updated_at,
    NULL::timestamptz AS deleted_at,
    '全局'::character varying AS tenant_name,
    (SELECT count(*) FROM iam_role_api ra WHERE ra.role_code = r.role_code) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_code = r.role_code) AS menu_count,
    (SELECT count(*) FROM user_role ur WHERE ur.role_code = r.role_code) AS users_count  -- 034: 真实计数
FROM role r;
COMMENT ON VIEW api_v1_public.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数；034 users_count 改真实计数）';

-- ---------------------------------------------------------------------------
-- §3 user_role 视图 → user_tenants 更名（消除与 public.user_role 表同名冲突）
--    列 = 表列（user_id / organization_id / joined_at）——与 views/user_tenants.sql 一致
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.user_role CASCADE;
DROP VIEW IF EXISTS api_v1_public.user_tenants CASCADE;
CREATE OR REPLACE VIEW api_v1_public.user_tenants AS
SELECT
    ut.user_id,
    ut.organization_id,        -- Logto 组织 id（= 租户 id）
    ut.joined_at
FROM user_tenants ut;
COMMENT ON VIEW api_v1_public.user_tenants IS '用户-组织成员关系视图（Logto 镜像：user_tenants；034 由 user_role 更名，消除与 public.user_role 表同名冲突）';

-- ---------------------------------------------------------------------------
-- §4 GRANT 补齐（条件授权幂等；源文件 grant_all.sql 已同步）
--    补: user_tenants / dict_type / dict_data / v_dict_list
--    不补: login_log（租户管理员走 rpc_search_login_logs）、
--          v_user_roles / v_role_users（RLS=超管OR本人，仅超管可用）
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_views text[] := ARRAY['user_tenants','dict_type','dict_data','v_dict_list'];
        v_view  text;
BEGIN
    FOREACH v_view IN ARRAY v_views LOOP
        IF to_regclass(format('api_v1_public.%I', v_view)) IS NOT NULL THEN
            EXECUTE format('GRANT SELECT ON api_v1_public.%I TO authenticated', v_view);
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- §5 pg_cron 任务重调度（失效路径修复）
--    cleanup-expired-tokens: api_v1.cleanup_expired_tokens()（015 已删）→
--                             api_v1_public.cleanup_expired_tokens()（029 新 wrapper）
--    cleanup-old-audit-logs: DELETE FROM sys_audit_log（014 已更名 audit_log）→
--                            DELETE FROM audit_log（保留 90 天）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-expired-tokens');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时忽略
END $$;
SELECT cron.schedule('cleanup-expired-tokens', '0 * * * *',
    $$ SELECT api_v1_public.cleanup_expired_tokens() $$);

DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-old-audit-logs');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;
SELECT cron.schedule('cleanup-old-audit-logs', '0 3 * * *',
    $$ DELETE FROM audit_log WHERE created_at < now() - interval '90 days' $$);

-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_role_active  boolean;
    v_users_count  boolean;
    v_ut_view      int;
    v_user_role_vw int;
    v_grants       int;
    v_cron         int;
BEGIN
    SELECT is_active INTO v_role_active FROM api_v1_public.role LIMIT 1;
    SELECT pg_get_viewdef('api_v1_public.v_role_list'::regclass, true)
        LIKE '%FROM user_role ur%' INTO v_users_count;
    SELECT count(*) INTO v_ut_view FROM pg_views
      WHERE schemaname='api_v1_public' AND viewname = 'user_tenants';
    SELECT count(*) INTO v_user_role_vw FROM pg_views
      WHERE schemaname='api_v1_public' AND viewname = 'user_role';
    SELECT count(*) INTO v_grants FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'api_v1_public'
        AND c.relname IN ('dict_type','dict_data','v_dict_list')
        AND has_table_privilege('authenticated', format('%I.%I', n.nspname, c.relname), 'SELECT');
    SELECT count(*) INTO v_cron FROM cron.job
      WHERE jobname IN ('cleanup-expired-tokens','cleanup-old-audit-logs');
    RAISE NOTICE '034: role.is_active=% users_count子查询=% user_tenants视图=% user_role残留=% authenticated可读视图数=% cron任务=%',
        v_role_active, v_users_count, v_ut_view, v_user_role_vw, v_grants, v_cron;
END $$;
