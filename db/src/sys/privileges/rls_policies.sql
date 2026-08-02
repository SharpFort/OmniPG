-- db/src/sys/privileges/rls_policies.sql
-- RLS 行级安全策略（租户隔离 + 部门隔离）
-- 来源: 20260707000008_enable_rls_policies.sql
-- Phase 1 适配: sys_user 表 → casdoor_user_mirror + sys_user_profile（D3/D4/D5）
-- 幂等: 全部 DROP POLICY IF EXISTS + CREATE POLICY（apply-src 可重复执行）

-- =============================================================================
-- sys_tenant 表：租户隔离（用户只能看到自己租户）
-- =============================================================================
ALTER TABLE sys_tenant ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation_policy ON sys_tenant;
CREATE POLICY tenant_isolation_policy ON sys_tenant
AS RESTRICTIVE
USING (id = current_tenant_id())
WITH CHECK (id = current_tenant_id());

-- =============================================================================
-- sys_department 表：租户隔离
-- =============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dept_tenant_isolation_policy ON sys_department;
CREATE POLICY dept_tenant_isolation_policy ON sys_department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- casdoor_user_mirror 表（Phase 1: 替代 sys_user）：
--   多租户隔离经 sys_user_profile 关联判定 + 本人可见 + 超管全量
--   注意: PERMISSIVE（仅 RESTRICTIVE 时所有行被默认拒绝，PG RLS 语义）
-- =============================================================================
ALTER TABLE casdoor_user_mirror ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mirror_tenant_policy ON casdoor_user_mirror;
CREATE POLICY mirror_tenant_policy ON casdoor_user_mirror
USING (
    is_super_admin()
    OR id = current_user_id()
    OR EXISTS (
        SELECT 1 FROM sys_user_profile p
        WHERE p.user_id = casdoor_user_mirror.id
          AND p.tenant_id = current_tenant_id()
          AND p.deleted_at IS NULL
    )
);

-- =============================================================================
-- sys_user_profile 表（Phase 1: 业务档案，租户隔离）
-- =============================================================================
ALTER TABLE sys_user_profile ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_tenant_policy ON sys_user_profile;
CREATE POLICY profile_tenant_policy ON sys_user_profile
USING (
    is_super_admin()
    OR id = current_user_id()
    OR tenant_id = current_tenant_id()
);

-- =============================================================================
-- sys_role 表：全局角色（tenant_id=NULL）所有租户可见，租户角色仅本租户可见
-- =============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_tenant_isolation_policy ON sys_role;
CREATE POLICY role_tenant_isolation_policy ON sys_role
AS RESTRICTIVE
USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- sys_api 表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_read_policy ON sys_api;
CREATE POLICY api_read_policy ON sys_api
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- sys_menu 表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_read_policy ON sys_menu;
CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- sys_user_role 表：通过 user 表继承租户隔离
-- =============================================================================
ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_role_tenant_policy ON sys_user_role;
CREATE POLICY user_role_tenant_policy ON sys_user_role
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- sys_user_session 表：用户只能看到自己的会话
-- =============================================================================
ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS session_user_policy ON sys_user_session;
CREATE POLICY session_user_policy ON sys_user_session
FOR SELECT
USING (user_id = current_user_id());

-- =============================================================================
-- sys_token_blacklist 表：系统级，仅 SECURITY DEFINER 函数访问
-- =============================================================================
ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS blacklist_system_policy ON sys_token_blacklist;
CREATE POLICY blacklist_system_policy ON sys_token_blacklist
AS RESTRICTIVE
USING (is_super_admin());

-- =============================================================================
-- sys_secret 表：系统级，仅 SECURITY DEFINER 函数访问
-- =============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS secret_system_policy ON sys_secret;
CREATE POLICY secret_system_policy ON sys_secret
AS RESTRICTIVE
USING (is_super_admin());

-- =============================================================================
-- sys_user_role_request 表：租户隔离
-- =============================================================================
ALTER TABLE sys_user_role_request ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS request_tenant_policy ON sys_user_role_request;
CREATE POLICY request_tenant_policy ON sys_user_role_request
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());
