-- db/api_v1/sys/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.1 web_anon: 仅可调用登录函数
-- =============================================================================
-- GRANT EXECUTE ON FUNCTION api_v1_sys.user_login_sso(text, text) TO web_anon;  -- 已在 rpc 中设置

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
-- =============================================================================
GRANT SELECT ON api_v1_sys.sys_tenant TO authenticated;
GRANT SELECT ON api_v1_sys.sys_department TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role TO authenticated;
GRANT SELECT ON api_v1_sys.sys_api TO authenticated;
GRANT SELECT ON api_v1_sys.sys_menu TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user_role TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role_api TO authenticated;
GRANT SELECT ON api_v1_sys.sys_role_menu TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user_session TO authenticated;
GRANT SELECT ON api_v1_sys.sys_user_role_request TO authenticated;
-- Phase 1: sys_audit_log/sys_cron_log/sys_config 视图依赖既有技术债，暂缓授权
-- GRANT SELECT ON api_v1_sys.sys_audit_log TO authenticated;
-- GRANT SELECT ON api_v1_sys.sys_cron_log TO authenticated;
-- GRANT SELECT ON api_v1_sys.sys_config TO authenticated;
-- Phase 1: 镜像表/档案表只读 GRANT 见迁移 007（此处不重复，避免依赖视图重建顺序）

-- 视图查询权限
GRANT SELECT ON api_v1_sys.v_user_list TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_list TO authenticated;
GRANT SELECT ON api_v1_sys.v_dept_list TO authenticated;
-- Phase 1: 审计视图依赖旧结构 audit 表（既有技术债），暂缓授权
-- GRANT SELECT ON api_v1_sys.v_audit_log_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_system_stats TO authenticated;
GRANT SELECT ON api_v1_sys.v_user_role_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_api_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_menu_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_role_request_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_online_users TO authenticated;
-- GRANT SELECT ON api_v1_sys.v_audit_log_timeline TO authenticated;
GRANT SELECT ON api_v1_sys.v_token_blacklist_detail TO authenticated;
GRANT SELECT ON api_v1_sys.v_system_stats_realtime TO authenticated;

-- 补充 P0 新增的批量操作 RPC GRANT
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_update_user_status(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_assign_roles(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_remove_roles(uuid, uuid[]) TO authenticated;

-- 补充 P1 新增配置管理 RPC GRANT
GRANT EXECUTE ON FUNCTION api_v1_sys.get_config(text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.get_all_public_configs() TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.update_config(text, text) TO authenticated;

-- 补充 P1 新增通用导入导出 RPC GRANT
GRANT EXECUTE ON FUNCTION api_v1_sys.export_csv(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_sys.import_csv(text, jsonb, boolean) TO authenticated;

-- =============================================================================
-- 3.3 role_guest: 只读访问（同 authenticated）
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_guest;

-- =============================================================================
-- 3.4 role_editor: 可编辑内容
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_editor;
GRANT INSERT, UPDATE ON api_v1_sys.sys_user_role_request TO role_editor;
GRANT USAGE ON SCHEMA api_v1_sys TO role_editor;

-- =============================================================================
-- 3.5 role_admin: 管理系统表
-- =============================================================================
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1_sys TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_department TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_user TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_user_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_user_role_request TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1_sys.sys_menu TO role_admin;
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
