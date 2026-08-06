-- db/api_v1/sys/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）— T7 重写（Logto 语义）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
--     注意: sys_tenant/sys_user_session/sys_user_role_request 视图已退役（T7）
-- =============================================================================
GRANT SELECT ON api_v1_public.department TO authenticated;
GRANT SELECT ON api_v1_public.users TO authenticated;
GRANT SELECT ON api_v1_public.role TO authenticated;
GRANT SELECT ON api_v1_public.iam_api TO authenticated;
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT SELECT ON api_v1_public.user_role TO authenticated;
GRANT SELECT ON api_v1_public.iam_role_api TO authenticated;
GRANT SELECT ON api_v1_public.iam_role_menu TO authenticated;
GRANT SELECT ON api_v1_public.audit_log TO authenticated;
GRANT SELECT ON api_v1_public.cron_job_log TO authenticated;
GRANT SELECT ON api_v1_public.app_config TO authenticated;
GRANT SELECT ON api_v1_public.config_admin TO authenticated;

-- 视图查询权限（v_user_list/v_role_list 为前端核心；v_* 明细视图）
GRANT SELECT ON api_v1_public.v_user_list TO authenticated;
GRANT SELECT ON api_v1_public.v_role_list TO authenticated;
GRANT SELECT ON api_v1_public.v_dept_list TO authenticated;
GRANT SELECT ON api_v1_public.v_system_stats TO authenticated;
GRANT SELECT ON api_v1_public.v_user_role_detail TO authenticated;
GRANT SELECT ON api_v1_public.v_role_api_detail TO authenticated;
GRANT SELECT ON api_v1_public.v_role_menu_detail TO authenticated;
GRANT SELECT ON api_v1_public.v_audit_log_timeline TO authenticated;
GRANT SELECT ON api_v1_public.v_audit_log_detail TO authenticated;
GRANT SELECT ON api_v1_public.v_system_stats_realtime TO authenticated;

-- =============================================================================
-- 3.3 role_guest: 只读访问（同 authenticated）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_public TO role_guest;

-- =============================================================================
-- 3.4 role_editor: 可编辑内容
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_public TO role_editor;
GRANT USAGE ON SCHEMA api_v1_public TO role_editor;

-- =============================================================================
-- 3.5 role_admin: 管理系统表（业务自主数据可写；Logto 镜像表只读——经 RLS/API）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_public TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.department TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.users TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.role TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.iam_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.iam_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.iam_role_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.iam_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_public.app_config TO role_admin;
GRANT USAGE ON SCHEMA api_v1_public TO role_admin;

-- role_admin 也使用软删除
REVOKE DELETE ON ALL TABLES IN SCHEMA api_v1_public FROM role_admin;

-- =============================================================================
-- 3.6 super_admin: 完全控制
-- =============================================================================
GRANT ALL ON ALL TABLES IN SCHEMA api_v1_public TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA api_v1_public TO super_admin;
GRANT USAGE ON SCHEMA api_v1_public TO super_admin;
-- webhook 入口（web_anon 无 token 调用）+ JWT fallback 角色 + RLS 中间角色
GRANT USAGE ON SCHEMA api_v1_public TO web_anon, role_guest, authenticated;
