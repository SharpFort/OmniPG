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
RETURNS varchar AS $$
    SELECT current_setting('request.jwt.claims', true)::json->>'tenant_id';
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

-- ==============================================================================
-- [修复 P0-3] sys_secret 表 RLS — 仅超级管理员可读
-- ==============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

CREATE POLICY secret_no_anonymous ON sys_secret
AS RESTRICTIVE USING (false);

CREATE POLICY secret_read_policy ON sys_secret
FOR SELECT
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

-- ==============================================================================
-- sys_user 表 RLS
-- ==============================================================================
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;

-- 策略 1：租户隔离（RESTRICTIVE，强制所有查询带 tenant_id 过滤）
CREATE POLICY tenant_isolation_strict_policy ON sys_user
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- 策略 2：部门数据隔离（普通员工只看自己部门）
CREATE POLICY employee_dept_isolation_policy ON sys_user
FOR SELECT
USING (
    -- 超级管理员无视 RLS
    current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin'
    -- 同部门可见
    OR dept_id = current_user_dept_id()
    -- 自己可见自己
    OR id = current_user_id()
);

-- ==============================================================================
-- sys_department 表 RLS
-- ==============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

CREATE POLICY dept_tenant_isolation ON sys_department
AS RESTRICTIVE
USING (true);  -- 部门表不按租户隔离

-- ==============================================================================
-- sys_role 表 RLS（仅超级管理员可写）
-- ==============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_read_policy ON sys_role
FOR SELECT
USING (true);  -- 所有认证用户可读

-- ==============================================================================
-- sys_menu 表 RLS
-- ==============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (true);

-- ==============================================================================
-- [修复 P1-2] RLS 扩展到所有 11 张业务表
-- ==============================================================================

ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;
CREATE POLICY api_read_policy ON sys_api FOR SELECT USING (true);
CREATE POLICY api_write_policy ON sys_api FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_role_read_policy ON sys_user_role FOR SELECT USING (true);
CREATE POLICY user_role_write_policy ON sys_user_role FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_role_api ENABLE ROW LEVEL SECURITY;
CREATE POLICY role_api_read_policy ON sys_role_api FOR SELECT USING (true);
CREATE POLICY role_api_write_policy ON sys_role_api FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_read_policy ON sys_user_session FOR SELECT
USING (user_id = current_user_id() OR current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');
CREATE POLICY session_write_policy ON sys_user_session FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;
CREATE POLICY blacklist_internal ON sys_token_blacklist AS RESTRICTIVE USING (false);

ALTER TABLE sys_user_role_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY request_read_policy ON sys_user_role_request FOR SELECT
USING (applicant_id = current_user_id() OR current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');
CREATE POLICY request_write_policy ON sys_user_role_request FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY menu_write_policy ON sys_menu FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY dept_write_policy ON sys_department FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY role_write_policy ON sys_role FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

-- migrate:down

DROP POLICY IF EXISTS secret_read_policy ON sys_secret;
DROP POLICY IF EXISTS secret_no_anonymous ON sys_secret;
ALTER TABLE sys_secret DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_read_policy ON sys_api;
DROP POLICY IF EXISTS api_write_policy ON sys_api;
ALTER TABLE sys_api DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_role_read_policy ON sys_user_role;
DROP POLICY IF EXISTS user_role_write_policy ON sys_user_role;
ALTER TABLE sys_user_role DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_api_read_policy ON sys_role_api;
DROP POLICY IF EXISTS role_api_write_policy ON sys_role_api;
ALTER TABLE sys_role_api DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS session_read_policy ON sys_user_session;
DROP POLICY IF EXISTS session_write_policy ON sys_user_session;
ALTER TABLE sys_user_session DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS blacklist_internal ON sys_token_blacklist;
ALTER TABLE sys_token_blacklist DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS request_read_policy ON sys_user_role_request;
DROP POLICY IF EXISTS request_write_policy ON sys_user_role_request;
ALTER TABLE sys_user_role_request DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_write_policy ON sys_role;
DROP POLICY IF EXISTS role_read_policy ON sys_role;
ALTER TABLE sys_role DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_write_policy ON sys_menu;
DROP POLICY IF EXISTS menu_read_policy ON sys_menu;
ALTER TABLE sys_menu DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dept_write_policy ON sys_department;
DROP POLICY IF EXISTS dept_tenant_isolation ON sys_department;
ALTER TABLE sys_department DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_dept_isolation_policy ON sys_user;
DROP POLICY IF EXISTS tenant_isolation_strict_policy ON sys_user;
ALTER TABLE sys_user DISABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS current_user_dept_id();
DROP FUNCTION IF EXISTS current_tenant_id();
DROP FUNCTION IF EXISTS current_user_id();
