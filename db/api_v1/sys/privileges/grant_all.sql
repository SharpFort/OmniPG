-- db/api_v1/sys/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.1 web_anon: 仅可调用登录函数
-- =============================================================================
-- GRANT EXECUTE ON FUNCTION api_v1.user_login_sso(text, text) TO web_anon;  -- 已在 rpc 中设置

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
-- =============================================================================
GRANT SELECT ON api_v1.sys_tenant TO authenticated;
GRANT SELECT ON api_v1.sys_department TO authenticated;
GRANT SELECT ON api_v1.sys_user TO authenticated;
GRANT SELECT ON api_v1.sys_role TO authenticated;
GRANT SELECT ON api_v1.sys_api TO authenticated;
GRANT SELECT ON api_v1.sys_menu TO authenticated;
GRANT SELECT ON api_v1.sys_user_role TO authenticated;
GRANT SELECT ON api_v1.sys_role_api TO authenticated;
GRANT SELECT ON api_v1.sys_role_menu TO authenticated;
GRANT SELECT ON api_v1.sys_user_session TO authenticated;
GRANT SELECT ON api_v1.sys_user_role_request TO authenticated;
GRANT SELECT ON api_v1.sys_audit_log TO authenticated;
GRANT SELECT ON api_v1.sys_cron_log TO authenticated;

-- =============================================================================
-- 3.3 role_guest: 只读访问（同 authenticated）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_guest;

-- =============================================================================
-- 3.4 role_editor: 可编辑内容
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_editor;
GRANT INSERT, UPDATE ON api_v1.sys_user_role_request TO role_editor;
GRANT USAGE ON SCHEMA api_v1 TO role_editor;

-- =============================================================================
-- 3.5 role_admin: 管理系统表
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_department TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user_role_request TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_menu TO role_admin;
GRANT USAGE ON SCHEMA api_v1 TO role_admin;

-- role_admin 也使用软删除
REVOKE DELETE ON ALL TABLES IN SCHEMA api_v1 FROM role_admin;

-- =============================================================================
-- 3.6 super_admin: 完全控制
-- =============================================================================
GRANT ALL ON ALL TABLES IN SCHEMA api_v1 TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA api_v1 TO super_admin;
GRANT USAGE ON SCHEMA api_v1 TO super_admin;
