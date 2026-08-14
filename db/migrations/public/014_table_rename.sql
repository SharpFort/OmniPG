-- =============================================================================
-- 014_table_rename.sql — T7: sys_* 表处置（移除 7 + 重命名 5）
-- =============================================================================
-- 依据: 05 §10.2 资产处置清单 + 011（iam_api/iam_menu 自主表已接管）
--  移除: sys_api/sys_menu（数据已迁 iam_*）、sys_tenant（已退役）、
--        sys_user_legacy（快照）、sys_token_blacklist/sys_user_session（D12 不启用）、
--        sys_secret（Casdoor JWT 私钥，Logto 用 JWKS）
--  重命名: sys_audit_log→audit_log、sys_config→app_config、sys_cron_log→cron_job_log、
--        sys_department→department、sys_user_profile→user_profile
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- 注意: ALTER TABLE RENAME 自动更新同库视图/策略/函数引用。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 先重建 sys_api/sys_menu 视图指向 iam_*（旧表移除前视图不能悬空）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_api CASCADE;


DROP VIEW IF EXISTS api_v1_sys.sys_menu CASCADE;


-- 修正 013 的 JOIN 错误：v_role_api_detail 应 JOIN iam_api（api_id 指向 iam_api.id）
DROP VIEW IF EXISTS api_v1_sys.v_role_api_detail CASCADE;


-- 修正 013：v_role_menu_detail 应 JOIN iam_menu（列名 menu_name）



-- ---------------------------------------------------------------------------
-- §2 移除被退役表的 api 视图（sys_tenant/sys_secret/sys_token_blacklist/
--     sys_user_session —— 对应表将删除，视图一并退役）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_tenant CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_secret CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_token_blacklist CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_user_session CASCADE;

-- ---------------------------------------------------------------------------
-- §3 重命名 5 张保留表（ALTER RENAME 自动级联更新视图/策略引用）
--     幂等：仅当旧表名存在时执行（重复重放安全）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- 幂等修正（2026-08-14）：005 等 CREATE TABLE IF NOT EXISTS 在重放第二遍会重建
    -- 旧表，RENAME 需同时守卫目标不存在（否则 audit_log 等已存在冲突）
    IF to_regclass('public.sys_audit_log') IS NOT NULL AND to_regclass('public.audit_log') IS NULL THEN
        ALTER TABLE public.sys_audit_log RENAME TO audit_log;
    END IF;
    IF to_regclass('public.sys_config') IS NOT NULL AND to_regclass('public.app_config') IS NULL THEN
        ALTER TABLE public.sys_config RENAME TO app_config;
    END IF;
    IF to_regclass('public.sys_cron_log') IS NOT NULL AND to_regclass('public.cron_job_log') IS NULL THEN
        ALTER TABLE public.sys_cron_log RENAME TO cron_job_log;
    END IF;
    IF to_regclass('public.sys_department') IS NOT NULL AND to_regclass('public.department') IS NULL THEN
        ALTER TABLE public.sys_department RENAME TO department;
    END IF;
    IF to_regclass('public.sys_user_profile') IS NOT NULL AND to_regclass('public.user_profile') IS NULL THEN
        ALTER TABLE public.sys_user_profile RENAME TO user_profile;
    END IF;
END $$;

-- 重命名后重建引用新表名的统计视图（sys_user_session/sys_token_blacklist 已退役）



-- ---------------------------------------------------------------------------
-- §4 删除 7 张退役表
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.sys_api CASCADE;
DROP TABLE IF EXISTS public.sys_menu CASCADE;
DROP TABLE IF EXISTS public.sys_tenant CASCADE;
DROP TABLE IF EXISTS public.sys_user_legacy CASCADE;
-- 17 号文档归位修正（2026-08-14）：001 建的 sys_user 表（Casdoor 时代）从未被删——
-- 012 的 D 段（public.sys_user 兼容视图，text 化重建）语义依赖它退役；Logto 由
-- users 镜像表接管，此处随退役批次一并删除（真实链 012 的 CREATE VIEW 依赖此）
DROP TABLE IF EXISTS public.sys_user CASCADE;
DROP TABLE IF EXISTS public.sys_token_blacklist CASCADE;
DROP TABLE IF EXISTS public.sys_user_session CASCADE;
DROP TABLE IF EXISTS public.sys_secret CASCADE;

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_remaining int;
    v_views int;
BEGIN
    SELECT count(*) INTO v_remaining FROM pg_tables
    WHERE schemaname='public' AND tablename LIKE 'sys\_%' AND tablename <> 'schema_migrations';
    SELECT count(*) INTO v_views FROM pg_views
    WHERE schemaname='api_v1_sys' AND viewname LIKE 'sys\_%';
    RAISE NOTICE '014: 剩余 public.sys_* 表=%（期望 0）, api_v1_sys.sys_* 视图=%（期望 0）', v_remaining, v_views;
END $$;
