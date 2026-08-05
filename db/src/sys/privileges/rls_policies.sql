-- db/src/sys/privileges/rls_policies.sql
-- RLS 行级安全策略（Logto 语义：镜像表租户隔离 + 自主表共享读）
-- 来源: 20260707000008_enable_rls_policies.sql（T7 重写）
-- Phase 2: users/tenants/user_tenants/role 镜像表 + iam_* 自主表 + user_profile
-- 幂等: 全部 DROP POLICY IF EXISTS + CREATE POLICY（apply-src 可重复执行）

-- =============================================================================
-- users 镜像表：租户隔离（超管全量 / 本人 / 同租户 profile 关联）
-- =============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_tenant_policy ON users;
CREATE POLICY users_tenant_policy ON users
USING (
    is_super_admin()
    OR id = current_user_id()
    OR EXISTS (
        SELECT 1 FROM user_profile p
        WHERE p.user_id = users.id
          AND p.tenant_id = current_tenant_id()
          AND p.deleted_at IS NULL
    )
);

-- =============================================================================
-- tenants 镜像表：Logto 组织（租户）目录，成员可见本组织
-- =============================================================================
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenants_read_policy ON tenants;
CREATE POLICY tenants_read_policy ON tenants
FOR SELECT
USING (
    is_super_admin()
    OR id = current_tenant_id()
    OR EXISTS (
        SELECT 1 FROM user_tenants ut
        WHERE ut.organization_id = tenants.id
          AND ut.user_id = current_user_id()
    )
);

-- =============================================================================
-- user_tenants 镜像表：成员关系，本人可见
-- =============================================================================
ALTER TABLE user_tenants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_tenants_policy ON user_tenants;
CREATE POLICY user_tenants_policy ON user_tenants
USING (
    is_super_admin()
    OR user_id = current_user_id()
    OR organization_id = current_tenant_id()
);

-- =============================================================================
-- role 镜像表：Logto 角色目录，全局只读（authenticated 仅 SELECT）
-- =============================================================================
ALTER TABLE role ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_read_policy ON role;
CREATE POLICY role_read_policy ON role
FOR SELECT
USING (true);

-- =============================================================================
-- user_profile 表（业务档案，租户隔离）
-- =============================================================================
ALTER TABLE user_profile ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_tenant_policy ON user_profile;
CREATE POLICY profile_tenant_policy ON user_profile
USING (
    is_super_admin()
    OR user_id = current_user_id()
    OR tenant_id = current_tenant_id()
);

-- =============================================================================
-- department 表：租户隔离
-- =============================================================================
ALTER TABLE department ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dept_tenant_isolation_policy ON department;
CREATE POLICY dept_tenant_isolation_policy ON department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- =============================================================================
-- iam_api 自主表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE iam_api ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_read_policy ON iam_api;
CREATE POLICY api_read_policy ON iam_api
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- iam_menu 自主表：系统级共享，所有认证用户可读
-- =============================================================================
ALTER TABLE iam_menu ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_read_policy ON iam_menu;
CREATE POLICY menu_read_policy ON iam_menu
FOR SELECT
USING (is_active = TRUE);

-- =============================================================================
-- iam_role_api / iam_role_menu 自主表：系统级共享读（绑定数据）
-- =============================================================================
ALTER TABLE iam_role_api ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_api_read_policy ON iam_role_api;
CREATE POLICY role_api_read_policy ON iam_role_api
FOR SELECT
USING (true);

ALTER TABLE iam_role_menu ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_menu_read_policy ON iam_role_menu;
CREATE POLICY role_menu_read_policy ON iam_role_menu
FOR SELECT
USING (true);

-- =============================================================================
-- audit_log 表：审计日志（写路径经 SECURITY DEFINER write_audit_log /
--   audit_trigger_func；读路径超管 + 本租户管理员）
-- =============================================================================
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_read_policy ON audit_log;
CREATE POLICY audit_log_read_policy ON audit_log
FOR SELECT
USING (is_super_admin() OR tenant_id = current_tenant_id());
