-- db/api_v1/sys/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）— T7 重写（Logto 语义）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
--     注意: sys_tenant/sys_user_session/sys_user_role_request 视图已退役（T7）
-- =============================================================================
GRANT SELECT ON api_v1_sys.sys_department TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role TO authenticated;
GRANT SELECT ON api_v1_sys.sys_api TO authenticated;
GRANT SELECT ON api_v1_sys.sys_menu TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user_role TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role_api TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role_menu TO authenticated;
GRANT SELECT ON api_v1_sys.sys_audit_log TO authenticated;
GRANT SELECT ON api_v1_sys.sys_cron_log TO authenticated;
GRANT SELECT ON api_v1_sys.sys_config TO authenticated;
GRANT SELECT ON api_v1_sys.sys_config_admin TO authenticated;

-- 视图查询权限（v_user_list/v_role_list 为前端核心；v_* 明细视图）
GRANT SELECT ON api_v1_sys.v_user_list TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_list TO authenticated;
GRANT SELECT ON api_v1_sys.v_dept_list TO authenticated;
GRANT SELECT ON api_v1_sys.v_system_stats TO authenticated;
GRANT SELECT ON api_v1_sys.v_user_role_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_api_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_menu_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_audit_log_timeline TO authenticated;
GRANT SELECT ON api_v1_sys.v_system_stats_realtime TO authenticated;

-- =============================================================================
-- 3.3 role_guest: 只读访问（同 authenticated）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_guest;

-- =============================================================================
-- 3.4 role_editor: 可编辑内容
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_editor;
GRANT USAGE ON SCHEMA api_v1_sys TO role_editor;

-- =============================================================================
-- 3.5 role_admin: 管理系统表（业务自主数据可写；Logto 镜像表只读——经 RLS/API）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_department TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_user TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_config TO role_admin;
GRANT USAGE ON SCHEMA api_v1_sys TO role_admin;

-- role_admin 也使用软删除
REVOKE DELETE ON ALL TABLES IN SCHEMA api_v1_sys FROM role_admin;

-- =============================================================================
-- 3.6 super_admin: 完全控制
-- =============================================================================
GRANT ALL ON ALL TABLES IN SCHEMA api_v1_sys TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA api_v1_sys TO super_admin;
GRANT USAGE ON SCHEMA api_v1_sys TO super_admin;
