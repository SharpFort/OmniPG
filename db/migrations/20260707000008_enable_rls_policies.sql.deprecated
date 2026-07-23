-- ==============================================================================
-- Migration 008: RLS 行级安全策略
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- RLS 助手函数：高性能读取 JWT 中的上下文
-- ==============================================================================
CREATE OR REPLACE FUNCTION current_user_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'user_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_id() IS '从 JWT 中提取当前用户 ID（STABLE 缓存优化）';

CREATE OR REPLACE FUNCTION current_tenant_id() 
RETURNS uuid AS $$
    SELECT (current_setting('request.jwt.claims', true)::json->>'tenant_id')::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_tenant_id() IS '从 JWT 中提取当前租户 ID';

CREATE OR REPLACE FUNCTION current_user_dept_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'dept_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_dept_id() IS '从 JWT 中提取当前部门 ID';

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean AS $$
    SELECT current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin';
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员';

-- ==============================================================================
-- sys_tenant 表：租户隔离（用户只能看到自己租户）
-- ==============================================================================
ALTER TABLE sys_tenant ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_policy ON sys_tenant
AS RESTRICTIVE
USING (id = current_tenant_id())
WITH CHECK (id = current_tenant_id());

-- ==============================================================================
-- sys_department 表：租户隔离
-- ==============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

CREATE POLICY dept_tenant_isolation_policy ON sys_department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_user 表：多租户隔离 + 部门数据隔离
-- ==============================================================================
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

-- ==============================================================================
-- sys_role 表：全局角色（tenant_id=NULL）所有租户可见，租户角色仅本租户可见
-- ==============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_tenant_isolation_policy ON sys_role
AS RESTRICTIVE
USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_api 表：系统级共享，所有认证用户可读
-- ==============================================================================
ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;

CREATE POLICY api_read_policy ON sys_api
FOR SELECT
USING (is_active = TRUE);

-- ==============================================================================
-- sys_menu 表：系统级共享，所有认证用户可读
-- ==============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (is_active = TRUE);

-- ==============================================================================
-- sys_user_role 表：通过 user 表继承租户隔离
-- ==============================================================================
ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_role_tenant_policy ON sys_user_role
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_user_session 表：用户只能看到自己的会话
-- ==============================================================================
ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;

CREATE POLICY session_user_policy ON sys_user_session
FOR SELECT
USING (user_id = current_user_id());

-- ==============================================================================
-- sys_token_blacklist 表：系统级，仅 SECURITY DEFINER 函数访问
-- ==============================================================================
ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;

CREATE POLICY blacklist_system_policy ON sys_token_blacklist
AS RESTRICTIVE
USING (is_super_admin());

-- ==============================================================================
-- sys_secret 表：系统级，仅 SECURITY DEFINER 函数访问
-- ==============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

CREATE POLICY secret_system_policy ON sys_secret
AS RESTRICTIVE
USING (is_super_admin());

-- ==============================================================================
-- sys_user_role_request 表：租户隔离
-- ==============================================================================
ALTER TABLE sys_user_role_request ENABLE ROW LEVEL SECURITY;

CREATE POLICY request_tenant_policy ON sys_user_role_request
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- migrate:down
DROP POLICY IF EXISTS request_tenant_policy ON sys_user_role_request;
ALTER TABLE sys_user_role_request DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS secret_system_policy ON sys_secret;
ALTER TABLE sys_secret DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS blacklist_system_policy ON sys_token_blacklist;
ALTER TABLE sys_token_blacklist DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_user_policy ON sys_user_session;
ALTER TABLE sys_user_session DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_role_tenant_policy ON sys_user_role;
ALTER TABLE sys_user_role DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS menu_read_policy ON sys_menu;
ALTER TABLE sys_menu DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS api_read_policy ON sys_api;
ALTER TABLE sys_api DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_tenant_isolation_policy ON sys_role;
ALTER TABLE sys_role DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_dept_isolation_policy ON sys_user;
DROP POLICY IF EXISTS user_tenant_isolation_policy ON sys_user;
ALTER TABLE sys_user DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dept_tenant_isolation_policy ON sys_department;
ALTER TABLE sys_department DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation_policy ON sys_tenant;
ALTER TABLE sys_tenant DISABLE ROW LEVEL SECURITY;
DROP FUNCTION IF EXISTS is_super_admin();
DROP FUNCTION IF EXISTS current_user_dept_id();
DROP FUNCTION IF EXISTS current_tenant_id();
DROP FUNCTION IF EXISTS current_user_id();
