-- 074_perf_fix_missing_indexes.sql
-- 074（2026-11-18）：物理性能与多租户索引精准重构
-- 内容：
--   1) 补齐真实缺失的外键与组织关联索引，消除级联删除与多表关联时的全表扫描与行级锁争用
--   2) 针对多租户 RLS 核心策略建立 (tenant_id, organization_id) 复合索引，消除 BitmapAnd 运算开销
--   3) 针对 has_permission() 权限判定高频热表 (iam_role_menu) 建立条件复合索引
-- migrate:up

-- =============================================================================
-- 1. 真实缺失的外键关联索引（已剔除 PK/唯一约束左前缀冗余项）
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_user_profile_dept_id ON platform.user_profile (dept_id);
CREATE INDEX IF NOT EXISTS idx_iam_menu_organization_id ON platform.iam_menu (organization_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_organization_id ON platform.iam_role_menu (organization_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_org_id ON platform.iam_role_data_scope (organization_id);
CREATE INDEX IF NOT EXISTS idx_app_config_tenant_id ON platform.app_config (tenant_id);
CREATE INDEX IF NOT EXISTS idx_app_config_organization_id ON platform.app_config (organization_id);
CREATE INDEX IF NOT EXISTS idx_cron_job_log_tenant_id ON platform.cron_job_log (tenant_id);
CREATE INDEX IF NOT EXISTS idx_cron_job_log_organization_id ON platform.cron_job_log (organization_id);
CREATE INDEX IF NOT EXISTS idx_webhook_event_log_tenant_id ON platform.webhook_event_log (tenant_id);
CREATE INDEX IF NOT EXISTS idx_webhook_event_log_organization_id ON platform.webhook_event_log (organization_id);

-- =============================================================================
-- 2. 多租户 RLS 行级隔离复合索引（tenant_id + organization_id）
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_department_tenant_org ON platform.department (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_position_tenant_org ON platform.position (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_user_position_tenant_org ON platform.user_position (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_user_profile_tenant_org ON platform.user_profile (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_dict_data_tenant_org ON platform.dict_data (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_dict_type_tenant_org ON platform.dict_type (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_tenant_org ON platform.audit_log (tenant_id, organization_id);
CREATE INDEX IF NOT EXISTS idx_login_log_tenant_org ON platform.login_log (tenant_id, organization_id);

-- =============================================================================
-- 3. 权限判定与高频查询专用复合/条件索引
-- =============================================================================
-- 优化 has_permission() 角色绑定判定: WHERE tenant_id = ... AND role_id/org_role_id = ANY(...)
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_tenant_role ON platform.iam_role_menu (tenant_id, role_id) WHERE role_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_tenant_org_role ON platform.iam_role_menu (tenant_id, org_role_id) WHERE org_role_id IS NOT NULL;
-- 优化 激活菜单租户过滤
CREATE INDEX IF NOT EXISTS idx_iam_menu_tenant_active ON platform.iam_menu (tenant_id) WHERE is_active = true;

-- migrate:down

DROP INDEX IF EXISTS platform.idx_user_profile_dept_id;
DROP INDEX IF EXISTS platform.idx_iam_menu_organization_id;
DROP INDEX IF EXISTS platform.idx_iam_role_menu_organization_id;
DROP INDEX IF EXISTS platform.idx_iam_role_data_scope_org_id;
DROP INDEX IF EXISTS platform.idx_app_config_tenant_id;
DROP INDEX IF EXISTS platform.idx_app_config_organization_id;
DROP INDEX IF EXISTS platform.idx_cron_job_log_tenant_id;
DROP INDEX IF EXISTS platform.idx_cron_job_log_organization_id;
DROP INDEX IF EXISTS platform.idx_webhook_event_log_tenant_id;
DROP INDEX IF EXISTS platform.idx_webhook_event_log_organization_id;

DROP INDEX IF EXISTS platform.idx_department_tenant_org;
DROP INDEX IF EXISTS platform.idx_position_tenant_org;
DROP INDEX IF EXISTS platform.idx_user_position_tenant_org;
DROP INDEX IF EXISTS platform.idx_user_profile_tenant_org;
DROP INDEX IF EXISTS platform.idx_dict_data_tenant_org;
DROP INDEX IF EXISTS platform.idx_dict_type_tenant_org;
DROP INDEX IF EXISTS platform.idx_audit_log_tenant_org;
DROP INDEX IF EXISTS platform.idx_login_log_tenant_org;

DROP INDEX IF EXISTS platform.idx_iam_role_menu_tenant_role;
DROP INDEX IF EXISTS platform.idx_iam_role_menu_tenant_org_role;
DROP INDEX IF EXISTS platform.idx_iam_menu_tenant_active;
