-- db/api_v1/platform/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）— T7 重写（Logto 语义）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
--     注意: sys_tenant/sys_user_session/sys_user_role_request 视图已退役（T7）
-- =============================================================================
GRANT SELECT ON api_v1_platform.department TO authenticated;
GRANT SELECT ON api_v1_platform.users TO authenticated;
GRANT SELECT ON api_v1_platform.role TO authenticated;
GRANT SELECT ON api_v1_platform.iam_menu TO authenticated;
GRANT SELECT ON api_v1_platform.user_tenants TO authenticated;  -- 034: 原 user_role 更名
GRANT SELECT ON api_v1_platform.iam_role_menu TO authenticated;
GRANT SELECT ON api_v1_platform.audit_log TO authenticated;
GRANT SELECT ON api_v1_platform.cron_job_log TO authenticated;
GRANT SELECT ON api_v1_platform.app_config TO authenticated;
GRANT SELECT ON api_v1_platform.config_admin TO authenticated;

-- 视图查询权限（v_user_list/v_role_list 为前端核心；v_* 明细视图）
GRANT SELECT ON api_v1_platform.v_user_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_role_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_dept_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_system_stats TO authenticated;
GRANT SELECT ON api_v1_platform.v_user_role_detail TO authenticated;
GRANT SELECT ON api_v1_platform.v_role_menu_detail TO authenticated;
GRANT SELECT ON api_v1_platform.v_audit_log_timeline TO authenticated;
GRANT SELECT ON api_v1_platform.v_audit_log_detail TO authenticated;
GRANT SELECT ON api_v1_platform.v_system_stats_realtime TO authenticated;

-- 034 补齐（023/024 建视图时漏授；login_log/v_user_roles/v_role_users 有意不授——
-- login_log 租户管理员走 rpc_search_login_logs；v_user_roles/v_role_users RLS=超管OR本人，仅超管可用）
GRANT SELECT ON api_v1_platform.dict_type TO authenticated;
GRANT SELECT ON api_v1_platform.dict_data TO authenticated;
GRANT SELECT ON api_v1_platform.v_dict_list TO authenticated;

-- =============================================================================
-- 3.3 role_guest: 只读访问（同 authenticated）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_platform TO role_guest;

-- =============================================================================
-- 3.4 role_editor: 可编辑内容
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_platform TO role_editor;
GRANT USAGE ON SCHEMA api_v1_platform TO role_editor;

-- =============================================================================
-- 3.5 role_admin: 管理系统表（业务自主数据可写；Logto 镜像表只读——经 RLS/API）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_platform TO role_admin;
GRANT INSERT, UPDATE ON api_v1_platform.department TO role_admin;
-- N4（2026-08-11）: 镜像表视图写授权撤销（镜像只读原则；写入通道仅 sync_*/JIT/对账）
REVOKE INSERT, UPDATE ON api_v1_platform.users FROM role_admin;
REVOKE INSERT, UPDATE ON api_v1_platform.role FROM role_admin;
GRANT INSERT, UPDATE ON api_v1_platform.iam_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_platform.iam_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_platform.app_config TO role_admin;
GRANT USAGE ON SCHEMA api_v1_platform TO role_admin;

-- role_admin 也使用软删除
REVOKE DELETE ON ALL TABLES IN SCHEMA api_v1_platform FROM role_admin;

-- =============================================================================
-- 3.6 super_admin: 完全控制
-- =============================================================================
GRANT ALL ON ALL TABLES IN SCHEMA api_v1_platform TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA api_v1_platform TO super_admin;
GRANT USAGE ON SCHEMA api_v1_platform TO super_admin;
-- webhook 入口（web_anon 无 token 调用）+ JWT fallback 角色 + RLS 中间角色
GRANT USAGE ON SCHEMA api_v1_platform TO web_anon, role_guest, authenticated;
