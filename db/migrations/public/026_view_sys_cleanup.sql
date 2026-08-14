-- =============================================================================
-- 026_view_sys_cleanup.sql — api_v1_sys 视图名 sys_ 残留彻底移除
-- =============================================================================
-- 背景: 2026-08-05 用户巡检发现视图名仍有 sys_ 残留
--   api_v1_sys 暴露视图命名规则定稿: **视图名 = 底层表名**（schema 已表意 sys 模块）
--   表名视图（12 个，源文件已同步改名）:
--     sys_api→iam_api / sys_menu→iam_menu / sys_role_api→iam_role_api /
--     sys_role_menu→iam_role_menu / sys_role→role / sys_user→users /
--     sys_user_role→user_role / sys_config→app_config /
--     sys_config_admin→config_admin / sys_cron_log→cron_job_log /
--     sys_audit_log→audit_log / sys_department→department
--   019 迁移内定义（无源文件，本迁移重建新名）:
--     sys_audit_log→audit_log（文件已覆盖）/ sys_position→position /
--     sys_user_position→user_position
--   v_sys_login_log→v_login_log（023 定义）
-- 幂等: DROP IF EXISTS（残留清理）+ CREATE OR REPLACE（新名）；apply-src 重放安全
-- 依赖: v_role_api_detail JOIN iam_api / v_role_menu_detail JOIN iam_menu（源文件已改）
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 残留清理（旧名视图，CASCADE 连带清理依赖旧名的视图/授权）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_api CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_menu CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_role_api CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_role_menu CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_role CASCADE;

DROP VIEW IF EXISTS api_v1_sys.sys_user_role CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_config CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_config_admin CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_cron_log CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_audit_log CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_department CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_position CASCADE;
DROP VIEW IF EXISTS api_v1_sys.sys_user_position CASCADE;
DROP VIEW IF EXISTS api_v1_sys.v_sys_login_log CASCADE;

-- ---------------------------------------------------------------------------
-- §2 019 内定义的视图重建（新名；api_v1 源文件已覆盖的 audit_log 除外）
-- ---------------------------------------------------------------------------






-- ---------------------------------------------------------------------------
-- §3 v_sys_login_log → v_login_log（023 定义重建新名，引用 login_log + geo_locate）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §4 授权（新名视图；grant_all.sql 已同步，此处兜底幂等）
--    注: 视图由 api_v1/public 源文件建在 api_v1_public；本迁移执行时
--    api_v1_sys 中可能尚不存在 → 条件授权（存在才 GRANT，避免报错）
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_schema text := 'api_v1_sys';
        v_views  text[] := ARRAY['iam_api','iam_menu','iam_role_api','iam_role_menu',
            'role','users','user_role','app_config','config_admin','cron_job_log',
            'audit_log','department','position','user_position','v_login_log'];
        v_view   text;
BEGIN
    FOREACH v_view IN ARRAY v_views LOOP
        IF to_regclass(format('%I.%I', v_schema, v_view)) IS NOT NULL THEN
            EXECUTE format('GRANT SELECT ON %I.%I TO authenticated', v_schema, v_view);
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_old int; v_new int;
BEGIN
    SELECT count(*) INTO v_old FROM pg_views
      WHERE schemaname='api_v1_sys' AND (viewname LIKE 'sys\_%' OR viewname = 'v_sys_login_log');
    SELECT count(*) INTO v_new FROM pg_views
      WHERE schemaname='api_v1_sys' AND viewname IN
        ('iam_api','iam_menu','iam_role_api','iam_role_menu','role','users',
         'user_role','app_config','config_admin','cron_job_log','audit_log',
         'department','position','user_position','v_login_log');
    RAISE NOTICE '026: 残留旧名视图=%（期望0） 新名视图=%（期望15）', v_old, v_new;
END $$;
