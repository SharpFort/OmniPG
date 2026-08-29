-- db/src/platform/privileges/rls_policies.sql
-- D27：业务表 RLS 统一按双维度过滤：
--   tenant_id（Logto 部署租户） + organization_id（Logto Organization）
-- 只读投影视图由 omnipg_logto_reader（BYPASSRLS）拥有，不启用 RLS。

-- =============================================================================
-- user_profile 表（个人档案，组织隔离）
-- =============================================================================
ALTER TABLE user_profile ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_tenant_policy ON user_profile;
CREATE POLICY profile_tenant_policy ON user_profile
USING (
    is_super_admin()
    OR user_id = current_user_id()
    OR (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id())
)
WITH CHECK (
    is_super_admin()
    OR user_id = current_user_id()
);

-- =============================================================================
-- department 表：租户+组织隔离
-- =============================================================================
ALTER TABLE department ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dept_tenant_isolation_policy ON department;
-- 必须 PERMISSIVE：本表无其他 permissive 策略，RESTRICTIVE 会与"无策略=默认拒绝"做 AND，
-- 等价于对 authenticated 全拒绝（get_dept_tree 恒返回空）
CREATE POLICY dept_tenant_isolation_policy ON department
USING (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id())
WITH CHECK (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id());

-- =============================================================================
-- iam_menu 自主表：按 Logto 租户系统级共享
-- =============================================================================
ALTER TABLE iam_menu ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_read_policy ON iam_menu;
CREATE POLICY menu_read_policy ON iam_menu
FOR SELECT
USING (is_active = TRUE AND tenant_id = current_logto_tenant_id());

-- =============================================================================
-- iam_role_menu 自主表：按 Logto 租户系统级共享读
-- =============================================================================
ALTER TABLE iam_role_menu ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_menu_read_policy ON iam_role_menu;
CREATE POLICY role_menu_read_policy ON iam_role_menu
FOR SELECT
USING (tenant_id = current_logto_tenant_id());

-- =============================================================================
-- audit_log 表：审计日志
-- =============================================================================
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_read_policy ON audit_log;
CREATE POLICY audit_log_read_policy ON audit_log
FOR SELECT
USING (is_super_admin() OR (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id()));

-- =============================================================================
-- dict_data 表（全局字典 organization_id IS NULL）
-- =============================================================================
ALTER TABLE dict_data ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dict_data_read_policy ON dict_data;
CREATE POLICY dict_data_read_policy ON platform.dict_data
FOR SELECT
USING (is_super_admin() OR (tenant_id = current_logto_tenant_id() AND (organization_id IS NULL OR organization_id = current_organization_id())));

-- =============================================================================
-- dict_type 表（全局字典 organization_id IS NULL）
-- =============================================================================
ALTER TABLE dict_type ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dict_type_read_policy ON dict_type;
CREATE POLICY dict_type_read_policy ON platform.dict_type
FOR SELECT
USING (is_super_admin() OR (tenant_id = current_logto_tenant_id() AND (organization_id IS NULL OR organization_id = current_organization_id())));

-- =============================================================================
-- ip_geolite2_city 表
-- =============================================================================
ALTER TABLE ip_geolite2_city ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS geolite2_read_policy ON ip_geolite2_city;
CREATE POLICY geolite2_read_policy ON platform.ip_geolite2_city
FOR SELECT
USING (tenant_id = current_logto_tenant_id());

-- =============================================================================
-- ip_region_v4 表
-- =============================================================================
ALTER TABLE ip_region_v4 ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ip_region_read_policy ON ip_region_v4;
CREATE POLICY ip_region_read_policy ON platform.ip_region_v4
FOR SELECT
USING (tenant_id = current_logto_tenant_id());

-- =============================================================================
-- login_log 表
-- =============================================================================
ALTER TABLE login_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS login_log_read_policy ON login_log;
CREATE POLICY login_log_read_policy ON platform.login_log
FOR SELECT
USING (is_super_admin() OR (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id()) OR user_id = current_user_id());

-- =============================================================================
-- position 表：租户+组织隔离
-- =============================================================================
ALTER TABLE position ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS position_tenant_isolation_policy ON position;
-- 同 department：必须 PERMISSIVE，否则 authenticated 全拒绝
CREATE POLICY position_tenant_isolation_policy ON platform.position
USING (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id())
WITH CHECK (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id());

-- =============================================================================
-- iam_role_data_scope 表
-- =============================================================================
ALTER TABLE iam_role_data_scope ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_data_scope_read_policy ON iam_role_data_scope;
CREATE POLICY role_data_scope_read_policy ON platform.iam_role_data_scope
FOR SELECT USING (tenant_id = current_logto_tenant_id());

-- =============================================================================
-- user_position 表：租户+组织隔离
-- =============================================================================
ALTER TABLE user_position ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_position_tenant_isolation_policy ON user_position;
-- 同 department：必须 PERMISSIVE，否则 authenticated 全拒绝
CREATE POLICY user_position_tenant_isolation_policy ON platform.user_position
USING (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id())
WITH CHECK (tenant_id = current_logto_tenant_id() AND organization_id = current_organization_id());

-- =============================================================================
-- webhook_event_log 表（仅超管）
-- =============================================================================
ALTER TABLE webhook_event_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS webhook_event_log_select_policy ON webhook_event_log;
CREATE POLICY webhook_event_log_select_policy ON webhook_event_log
FOR SELECT
USING (is_super_admin());
