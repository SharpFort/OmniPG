-- =============================================================================
-- 028_grant_trigger_fix.sql — 表级权限补齐 + 触发器名 sys_ 残留清理
-- =============================================================================
-- 背景: 2026-08-05 全面体检发现
--   ① 019/021/024 新表与 001 时代旧表（department/audit_log/app_config 等）
--      均无表级 GRANT——api_v1_public 视图为 INVOKER 权限，authenticated
--      经视图查询底层表会权限失败（009/016 只覆盖镜像表+授权表）
--   ② 触发器名残留 sys_：trg_audit_sys_department/trg_audit_sys_role_api/
--      trg_audit_sys_role_menu（与 023 新增 trg_audit_dict_type 等不一致）
-- 权限模型定稿:
--   - public schema = 系统管理域；authenticated 全表 SELECT + RLS 控行
--   - super_admin 全表 ALL（管理写路径经 SECURITY DEFINER RPC 已含门槛）
--   - staging 表（ip_geolite2_blocks/locations）不授予（仅导入脚本/内部函数）
-- 幂等: DROP IF EXISTS + CREATE / GRANT 可重复
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 表级 GRANT 补齐（authenticated SELECT；super_admin ALL）
-- ---------------------------------------------------------------------------
GRANT SELECT ON department        TO authenticated;
GRANT SELECT ON audit_log         TO authenticated;
GRANT SELECT ON app_config        TO authenticated;
GRANT SELECT ON cron_job_log      TO authenticated;
GRANT SELECT ON user_profile      TO authenticated;
GRANT SELECT ON position          TO authenticated;
GRANT SELECT ON user_position     TO authenticated;
GRANT SELECT ON dict_type         TO authenticated;
GRANT SELECT ON dict_data         TO authenticated;
GRANT SELECT ON login_log         TO authenticated;
GRANT SELECT ON ip_region_v4      TO authenticated;
GRANT SELECT ON ip_geolite2_city  TO authenticated;
GRANT SELECT ON user_role         TO authenticated;

GRANT ALL ON department, audit_log, app_config, cron_job_log, user_profile,
    position, user_position, dict_type, dict_data, login_log,
    ip_region_v4, ip_geolite2_city, user_role
    TO super_admin;

-- ---------------------------------------------------------------------------
-- §2 触发器名 sys_ 残留清理（与 023 命名对齐）
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_audit_sys_department ON department;
CREATE TRIGGER trg_audit_department
    AFTER INSERT OR UPDATE OR DELETE ON department
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_sys_role_api ON iam_role_api;
CREATE TRIGGER trg_audit_role_api
    AFTER INSERT OR UPDATE OR DELETE ON iam_role_api
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

DROP TRIGGER IF EXISTS trg_audit_sys_role_menu ON iam_role_menu;
CREATE TRIGGER trg_audit_role_menu
    AFTER INSERT OR UPDATE OR DELETE ON iam_role_menu
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_trg int; v_grants int;
BEGIN
    SELECT count(*) INTO v_trg FROM pg_trigger
      WHERE tgname LIKE 'trg_audit_sys_%' AND NOT tgisinternal;
    SELECT count(*) INTO v_grants FROM information_schema.role_table_grants
      WHERE grantee='authenticated' AND table_schema='public'
        AND table_name IN ('department','audit_log','app_config','cron_job_log',
                           'user_profile','position','user_position','dict_type',
                           'dict_data','login_log','ip_region_v4','ip_geolite2_city','user_role');
    RAISE NOTICE '028: 残留 sys_ 触发器=%（期望0） 表级授权=%（期望13）', v_trg, v_grants;
END $$;
