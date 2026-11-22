-- db/api_v1/platform/privileges/grant_all.sql
-- API v1 权限授予（按角色分层）— T7 重写（Logto 语义）
-- 来源: 20260707000013_postgrest_api_v1.sql

-- =============================================================================
-- 3.2 authenticated: 所有认证用户可读基础表
--     注意: sys_tenant/sys_user_session/sys_user_role_request 视图已退役（T7）
-- =============================================================================
GRANT SELECT ON api_v1_platform.department TO authenticated;
-- 2026-11-22 收口（citywalk 扫描 D 组 P0-1）：users 原授 authenticated——视图无谓词时
-- 经 owner 链（platform.users 投影 owner=BYPASSRLS reader）泄露全租户用户目录；
-- 视图已改 security_invoker+租户谓词，授权收归管理员（见文末收权段同步 REVOKE）
GRANT SELECT ON api_v1_platform.users TO role_admin, tenant_admin, super_admin;
GRANT SELECT ON api_v1_platform.role TO authenticated;
GRANT SELECT ON api_v1_platform.iam_menu TO authenticated;
GRANT SELECT ON api_v1_platform.tenants TO authenticated;          -- D27: Logto Tenant
GRANT SELECT ON api_v1_platform.organizations TO authenticated;    -- D27: Logto Organization
GRANT SELECT ON api_v1_platform.user_tenants TO authenticated;     -- D27: tenant_id/organization_id 双列
GRANT SELECT ON api_v1_platform.tenant_role TO authenticated;      -- D25: 原 organization_role 改名
GRANT SELECT ON api_v1_platform.iam_role_menu TO authenticated;
-- 2026-11-22 收口（citywalk 扫描 D 组 P0-2）：audit_log 视图为 invoker+基表 RLS
-- （租户+组织级而非管理员级），old_data/new_data 含变更前后完整快照；同数据的
-- v_audit_log_detail/login_log 已于 2026-11-19 收归管理员，本体属孤立遗漏
GRANT SELECT ON api_v1_platform.audit_log TO role_admin, tenant_admin, super_admin;
GRANT SELECT ON api_v1_platform.cron_job_log TO authenticated;
GRANT SELECT ON api_v1_platform.app_config TO authenticated;
-- 2026-11-19 收口：config_admin 暴露全部配置值（含 security.* 等非公开键），不再授予
-- authenticated，仅管理员角色；已授库由文末收权段 REVOKE
GRANT SELECT ON api_v1_platform.config_admin TO role_admin, tenant_admin, super_admin;

-- 视图查询权限（v_user_list/v_role_list 为前端核心；v_* 明细视图）
GRANT SELECT ON api_v1_platform.v_user_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_role_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_dept_list TO authenticated;
GRANT SELECT ON api_v1_platform.v_system_stats TO authenticated;
GRANT SELECT ON api_v1_platform.v_user_role_detail TO authenticated;
GRANT SELECT ON api_v1_platform.v_role_menu_detail TO authenticated;
-- 2026-11-22（P0-2 连带）：v_audit_log_timeline 改授管理员（行级边界=platform.audit_log
-- 基表 RLS，快照同级敏感；原 authenticated 授权在文末收权段同步 REVOKE）
GRANT SELECT ON api_v1_platform.v_audit_log_timeline TO role_admin, tenant_admin, super_admin;
-- 2026-11-19 收口：v_audit_log_detail join platform.users/tenants/organizations（owner 链路含
-- BYPASSRLS reader），仅管理员角色可用；已授库由文末收权段 REVOKE
GRANT SELECT ON api_v1_platform.v_audit_log_detail TO role_admin, tenant_admin, super_admin;
GRANT SELECT ON api_v1_platform.v_system_stats_realtime TO authenticated;

-- 034 补齐（023/024 建视图时漏授；login_log/v_user_roles/v_role_users 有意不授——
-- login_log 租户管理员走 rpc_search_login_logs；v_user_roles/v_role_users RLS=超管OR本人，仅超管可用）
GRANT SELECT ON api_v1_platform.dict_type TO authenticated;
GRANT SELECT ON api_v1_platform.dict_data TO authenticated;
GRANT SELECT ON api_v1_platform.v_dict_list TO authenticated;

-- 岗位管理/用户岗位页面补齐（漏授：position/user_position 视图一直无法经 PostgREST 读取）
GRANT SELECT ON api_v1_platform.position TO authenticated;
GRANT SELECT ON api_v1_platform.user_position TO authenticated;

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
-- 2026-11-19：配置写通道改走 config_admin（app_config 视图已加 is_public 过滤，
-- 经其写入非公开行会被自动 WITH CHECK 拒绝）；已授库由文末收权段 REVOKE
GRANT INSERT, UPDATE ON api_v1_platform.config_admin TO role_admin;
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

-- =============================================================================
-- 收权与 INVOKER 基表授权（2026-11-19 安全加固批）
-- =============================================================================

-- 1) 历史授权收口（幂等）：取消此前版本授出的过宽权限
--    a. config_admin / v_audit_log_detail 曾授予 authenticated —— 收归管理员
--    b. role_admin 曾对 app_config 视图可写 —— 写通道改走 config_admin
--    c. ALL TABLES 兜底与 034 显式排除冲突：login_log/v_login_log（管理员走
--       rpc_search_login_logs）、v_user_roles/v_role_users（034 注明仅超管）
--       不应对 guest/editor/admin 直读开放
REVOKE SELECT ON api_v1_platform.config_admin, api_v1_platform.v_audit_log_detail
    FROM authenticated;
REVOKE INSERT, UPDATE ON api_v1_platform.app_config FROM role_admin;
REVOKE SELECT ON api_v1_platform.login_log, api_v1_platform.v_login_log,
                api_v1_platform.v_user_roles, api_v1_platform.v_role_users,
                api_v1_platform.config_admin, api_v1_platform.v_audit_log_detail
    FROM role_guest, role_editor;
-- role_admin 保留 config_admin/v_audit_log_detail/audit_log 管理读权；但 login_log 家族
-- 按设计走 rpc_search_login_logs
REVOKE SELECT ON api_v1_platform.login_log, api_v1_platform.v_login_log,
                api_v1_platform.v_user_roles, api_v1_platform.v_role_users
    FROM role_admin;
-- _init_schema.sql 的 GRANT SELECT ON ALL TABLES IN SCHEMA platform 会对 platform.login_log
-- 重放全角色授权，这里同步收口（终态：login_log 底表仅 role_admin/super_admin）
REVOKE SELECT ON platform.login_log FROM authenticated, role_guest, role_editor;

-- 4) 2026-11-22 上游安全修复批（citywalk 全量扫描 D 组复核，P0-1）：
--    api_v1_platform.users / v_user_roles 已改 security_invoker+谓词（views/*.sql），
--    与 citywalk 侧临时收权（90_platform_view_hardening.sql）终态对齐——
--    C 端角色不再可读用户目录，管理端经 admin 角色不受影响
REVOKE SELECT ON api_v1_platform.users, api_v1_platform.v_user_roles
    FROM authenticated, role_guest, role_editor;

-- 5) 2026-11-22（P0-2）：audit_log 本体视图+基表收归管理员，与 v_audit_log_detail
--    对齐（见上方 3.2 段注释）。基表全角色授权（§2 原 L134-136）同步收敛——
--    invoker 视图行级边界=audit_log_read_policy（租户+组织级），快照数据不应
--    对非管理员开放；role_admin/tenant_admin/super_admin 经 §2 收敛后授权保持可读
REVOKE SELECT ON api_v1_platform.audit_log
    FROM authenticated, role_guest, role_editor;
REVOKE SELECT ON platform.audit_log FROM authenticated, role_guest, role_editor;
-- 连带收口：v_audit_log_timeline（invoker）与 SECURITY INVOKER RPC get_audit_log_timeline
-- 的行级边界同为本基表——基表收权后该链路对非管理员必然 42501，显式收权使语义
-- 一致（audit 系数据全量对齐管理员-only；99_revoke_public 先行批量授权，此处终态收口）
REVOKE SELECT ON api_v1_platform.v_audit_log_timeline
    FROM authenticated, role_guest, role_editor;
REVOKE EXECUTE ON FUNCTION api_v1_platform.get_audit_log_timeline(timestamp, timestamp, INTEGER)
    FROM authenticated, role_guest, role_editor;

-- 2) security_invoker 视图基表授权：INVOKER 视图以调用方身份访问基表，
--    调用方必须持有基表 SELECT；行级边界由 db/src/platform/privileges/rls_policies.sql 提供。
--    覆盖角色对齐 99_revoke_public.sql 约定（authenticated 基线 + 5 个登录角色）。
-- audit_log 基表（2026-11-22 P0-2 收敛）：仅管理员（invoker 视图链可达角色）——
-- 原「全六角色」授权使 authenticated/role_guest/role_editor 持基表 SELECT
GRANT SELECT ON platform.audit_log TO role_admin, tenant_admin, super_admin;
-- users/v_user_roles invoker 链基表授权（2026-11-22 P0-1）：
--   * platform.users / user_profile ← api_v1_platform.users（授权角色=视图可达角色：管理员）
--   * platform.user_role ← v_user_roles（可达角色仅 super_admin）
--   platform.users/user_role 为 BYPASSRLS reader 拥有的投影，行级边界=api 视图谓词；
--   platform schema 不在 PGRST_DB_SCHEMAS，无 HTTP 直达面
GRANT SELECT ON platform.users, platform.user_profile
    TO role_admin, tenant_admin, super_admin;
GRANT SELECT ON platform.user_role TO super_admin;
GRANT SELECT ON platform.department
    TO authenticated, role_guest, role_editor, role_admin, tenant_admin, super_admin;
GRANT SELECT ON platform.cron_job_log
    TO authenticated, role_guest, role_editor, role_admin, tenant_admin, super_admin;
GRANT SELECT ON platform.organizations
    TO authenticated, role_guest, role_editor, role_admin, tenant_admin, super_admin;
-- login_log 底表仅管理员（与上方 034 收口一致；RLS=超管OR本人OR本租户组织）
GRANT SELECT ON platform.login_log TO role_admin, tenant_admin, super_admin;
-- security_invoker 视图的写路径基表授权（2026-11-19 补丁）：api_v1.department 视图已
-- INVOKER 化，role_admin 经视图写入时以自身身份执行——需基表 INSERT/UPDATE，
-- 行级边界由 department RLS WITH CHECK（租户+组织）保证
GRANT INSERT, UPDATE ON platform.department TO role_admin;

-- 3) Logto 只读投影写权限收口（2026-11-20，e2e Users Readonly 显红驱动）：
--    N4「镜像只读原则」补全——:65-66 只对 role_admin 收了 users/role 的写权，
--    :80 的 ALL TABLES 兜底使 super_admin 仍持全部投影的 INSERT/UPDATE/DELETE/TRUNCATE。
--    后果：users 为 JOIN 视图不可自动更新 → 写请求在执行层报 55000 → PostgREST 返 500；
--    role/tenants/tenant_role 虽可更新但被基表 RLS 兜底返回 403，属侥幸通过而非设计保证。
--    终态：Logto 侧数据（users/role/tenants/tenant_role/organizations/user_tenants）的
--    唯一写入口是 Logto 本体（public 表）与 SECURITY DEFINER 同步函数——任何登录角色
--    经 API 写投影一律在 ACL 层 403 拒绝（含 super_admin）。
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    api_v1_platform.users, api_v1_platform.role, api_v1_platform.tenants,
    api_v1_platform.tenant_role, api_v1_platform.organizations,
    api_v1_platform.user_tenants
    FROM super_admin;
-- role_admin 同步收口 organizations/user_tenants/tenant_role（N4 只覆盖了 users/role；
-- role_admin 本无这三者的 DML 授权，此处幂等声明以防未来兜底授权引入回归）
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    api_v1_platform.users, api_v1_platform.role, api_v1_platform.tenants,
    api_v1_platform.tenant_role, api_v1_platform.organizations,
    api_v1_platform.user_tenants
    FROM role_admin, role_editor, role_guest, tenant_admin;
