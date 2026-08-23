-- pgTAP 测试：D25 只读投影视图 + 业务 RLS 辅助函数（D27：新增 logto tenant/organization helper）
BEGIN;
SELECT plan(11);

-- 1. 投影视图存在（Logto Tenant/Organization 一一对应）
SELECT has_view('tenants', 'platform.tenants（Logto Tenant）只读投影视图存在');
SELECT has_view('organizations', 'platform.organizations（Logto Organization）只读投影视图存在');
SELECT has_view('user_tenants', 'platform.user_tenants 只读投影视图存在');
SELECT has_view('role', 'platform.role 只读投影视图存在');

-- 2. 触发器存在（仅保留成员关系校验；存在性由 FK 保证）
SELECT has_function('validate_user_profile_refs', ARRAY[]::text[], 'validate_user_profile_refs() 函数存在');
SELECT has_function('validate_user_position_refs', ARRAY[]::text[], 'validate_user_position_refs() 函数存在');

-- 3. 辅助函数存在性（Logto claims 语义）
SELECT has_function('current_user_id', ARRAY[]::text[], 'current_user_id() 函数存在');
SELECT has_function('current_tenant_id', ARRAY[]::text[], 'current_tenant_id() 函数存在');
SELECT has_function('current_organization_id', ARRAY[]::text[], 'current_organization_id() 函数存在');
SELECT has_function('current_logto_tenant_id', ARRAY[]::text[], 'current_logto_tenant_id() 函数存在');
SELECT has_function('current_user_roles', ARRAY[]::text[], 'current_user_roles() 函数存在');

SELECT * FROM finish();
ROLLBACK;
