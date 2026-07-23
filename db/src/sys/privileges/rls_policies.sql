-- db/src/sys/privileges/rls_policies.sql
-- RLS 行级安全策略（租户隔离 + 部门隔离）
-- 来源: 20260707000008_enable_rls_policies.sql

-- =============================================================================
-- sys_tenant 表：租户隔离（用户只能看到自己租户）
-- =============================================================================
ALTER TABLE sys_tenant ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_policy ON sys_tenant
AS RESTRICTIVE
USING (id = current_tenant_id())
WITH CHECK (id = current_tenant_id());

-- =============================================================================
-- sys_department 表：租户隔离
-- =============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

CREATE POLICY dept_tenant_isolation_policy ON sys_department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- sys_user 表：多租户隔离 + 部门数据隔离
-- =============================================================================
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_tenant_isolation_policy ON sys_user
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY user_dept_isolation_policy ON sys_user
FOR SELECT
USING (
    is_super_admin()
    OR dept_id = current_user_dept_id()
    OR id = current_user_id()
);

-- =============================================================================
-- sys_role 表：全局角色（tenant_id=NULL）所有租户可见，租户角色仅本租户可见
-- =============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_tenant_isolation_policy ON sys_role
AS RESTRICTIVE
USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- sys_api 表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;

CREATE POLICY api_read_policy ON sys_api
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- sys_menu 表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- sys_user_role 表：通过 user 表继承租户隔离
-- =============================================================================
ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_role_tenant_policy ON sys_user_role
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- sys_user_session 表：用户只能看到自己的会话
-- =============================================================================
ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;

CREATE POLICY session_user_policy ON sys_user_session
FOR SELECT
USING (user_id = current_user_id());

-- =============================================================================
-- sys_token_blacklist 表：系统级，仅 SECURITY DEFINER 函数访问
-- =============================================================================
ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;

CREATE POLICY blacklist_system_policy ON sys_token_blacklist
AS RESTRICTIVE
USING (is_super_admin());

-- =============================================================================
-- sys_secret 表：系统级，仅 SECURITY DEFINER 函数访问
-- =============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

CREATE POLICY secret_system_policy ON sys_secret
AS RESTRICTIVE
USING (is_super_admin());

-- =============================================================================
-- sys_user_role_request 表：租户隔离
-- =============================================================================
ALTER TABLE sys_user_role_request ENABLE ROW LEVEL SECURITY;

CREATE POLICY request_tenant_policy ON sys_user_role_request
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());
