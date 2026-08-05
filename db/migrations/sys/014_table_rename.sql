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
CREATE VIEW api_v1_sys.sys_api AS
SELECT
    id, path, method,
    name AS api_name,          -- 兼容旧列名（011 列名修正）
    description, is_active, created_at, updated_at, created_by, updated_by
FROM iam_api;
COMMENT ON VIEW api_v1_sys.sys_api IS 'API 资源表视图（Logto 自主表：iam_api 投影）';

DROP VIEW IF EXISTS api_v1_sys.sys_menu CASCADE;
CREATE VIEW api_v1_sys.sys_menu AS
SELECT
    id, parent_id,
    menu_name AS name,         -- 兼容旧列名
    path, icon, order_num, is_active, created_at, updated_at, created_by, updated_by
FROM iam_menu;
COMMENT ON VIEW api_v1_sys.sys_menu IS '菜单权限表视图（Logto 自主表：iam_menu 投影）';

-- 修正 013 的 JOIN 错误：v_role_api_detail 应 JOIN iam_api（api_id 指向 iam_api.id）
DROP VIEW IF EXISTS api_v1_sys.v_role_api_detail CASCADE;
CREATE VIEW api_v1_sys.v_role_api_detail AS
SELECT
    ra.id AS role_id,
    ra.api_id,
    ra.created_at,
    ra.role_code,
    COALESCE(r.name, ra.role_code) AS role_name,
    a.path,
    a.method,
    a.name AS api_name,
    a.is_active AS api_is_active
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code
JOIN iam_api a ON a.id = ra.api_id;
COMMENT ON VIEW api_v1_sys.v_role_api_detail IS '角色-API 明细视图（Logto 镜像：iam_role_api→iam_api）';

-- 修正 013：v_role_menu_detail 应 JOIN iam_menu（列名 menu_name）
DROP VIEW IF EXISTS api_v1_sys.v_role_menu_detail CASCADE;
CREATE VIEW api_v1_sys.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.menu_name,
    NULL::text AS menu_type,
    NULL::text AS menu_title,
    NULL::text AS permission_code,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_sys.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu→iam_menu）';

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
    IF to_regclass('public.sys_audit_log') IS NOT NULL THEN
        ALTER TABLE public.sys_audit_log RENAME TO audit_log;
    END IF;
    IF to_regclass('public.sys_config') IS NOT NULL THEN
        ALTER TABLE public.sys_config RENAME TO app_config;
    END IF;
    IF to_regclass('public.sys_cron_log') IS NOT NULL THEN
        ALTER TABLE public.sys_cron_log RENAME TO cron_job_log;
    END IF;
    IF to_regclass('public.sys_department') IS NOT NULL THEN
        ALTER TABLE public.sys_department RENAME TO department;
    END IF;
    IF to_regclass('public.sys_user_profile') IS NOT NULL THEN
        ALTER TABLE public.sys_user_profile RENAME TO user_profile;
    END IF;
END $$;

-- 重命名后重建引用新表名的统计视图（sys_user_session/sys_token_blacklist 已退役）
DROP VIEW IF EXISTS api_v1_sys.v_system_stats_realtime CASCADE;
CREATE VIEW api_v1_sys.v_system_stats_realtime AS
SELECT
    (SELECT MAX(execution_time) FROM public.cron_job_log WHERE job_name = 'cleanup-expired-tokens') AS last_cleanup_time,
    (SELECT COUNT(*) FROM public.audit_log WHERE created_at > now() - interval '24 hours') AS audit_24h,
    now() AS stats_time;
COMMENT ON VIEW api_v1_sys.v_system_stats_realtime IS '实时系统统计视图（T7: 移除会话/黑名单计数）';

-- ---------------------------------------------------------------------------
-- §4 删除 7 张退役表
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.sys_api CASCADE;
DROP TABLE IF EXISTS public.sys_menu CASCADE;
DROP TABLE IF EXISTS public.sys_tenant CASCADE;
DROP TABLE IF EXISTS public.sys_user_legacy CASCADE;
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
