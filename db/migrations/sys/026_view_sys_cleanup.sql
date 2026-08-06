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
DROP VIEW IF EXISTS api_v1_sys.sys_user CASCADE;
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
DROP VIEW IF EXISTS api_v1_sys.position CASCADE;
CREATE VIEW api_v1_sys.position AS
SELECT id, tenant_id, pos_name, pos_code, parent_id, sort_no, status, remark,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM position;
COMMENT ON VIEW api_v1_sys.position IS '岗位视图（026：sys_position 去前缀）';

DROP VIEW IF EXISTS api_v1_sys.user_position CASCADE;
CREATE VIEW api_v1_sys.user_position AS
SELECT user_id, position_id, tenant_id, is_primary, created_at, created_by
FROM user_position;
COMMENT ON VIEW api_v1_sys.user_position IS '用户岗位关联视图（026：sys_user_position 去前缀）';

-- ---------------------------------------------------------------------------
-- §3 v_sys_login_log → v_login_log（023 定义重建新名，引用 login_log + geo_locate）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_login_log CASCADE;
CREATE VIEW api_v1_sys.v_login_log AS
SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type, l.result,
       l.fail_reason, l.ip, l.user_agent,
       l.region                 AS region_snapshot,
       g.region                 AS region_live,
       g.source                 AS geo_source,
       g.latitude, g.longitude, g.timezone,
       l.logto_event, l.created_at
FROM login_log l
LEFT JOIN LATERAL geo_locate(l.ip) g ON true;
COMMENT ON VIEW api_v1_sys.v_login_log IS '登录日志视图：login_log + geo_locate 实时地理（026：v_sys_login_log 去前缀）';

-- ---------------------------------------------------------------------------
-- §4 授权（新名视图；grant_all.sql 已同步，此处兜底幂等）
-- ---------------------------------------------------------------------------
GRANT SELECT ON api_v1_sys.iam_api, api_v1_sys.iam_menu, api_v1_sys.iam_role_api,
    api_v1_sys.iam_role_menu, api_v1_sys.role, api_v1_sys.users,
    api_v1_sys.user_role, api_v1_sys.app_config, api_v1_sys.config_admin,
    api_v1_sys.cron_job_log, api_v1_sys.audit_log, api_v1_sys.department,
    api_v1_sys.position, api_v1_sys.user_position, api_v1_sys.v_login_log
    TO authenticated;

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
