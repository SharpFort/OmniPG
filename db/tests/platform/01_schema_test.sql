-- 01_schema_test.sql：表/列/视图存在性验证（D27：Tenant/Organization 双语义 + 双列）
BEGIN;
SELECT plan(110);

-- 1. 只读投影视图存在性
SELECT has_view('users');
SELECT has_view('tenants');
SELECT has_view('organizations');
SELECT has_view('role');
SELECT has_view('tenant_role');
SELECT has_view('user_tenants');
SELECT has_view('user_role');

-- 2. 自主表/业务表存在性
SELECT hasnt_table('iam_api');
SELECT has_table('iam_menu');
SELECT hasnt_table('iam_role_api');
SELECT has_table('iam_role_menu');
SELECT has_table('user_profile');
SELECT has_table('department');
SELECT has_table('app_config');
SELECT has_table('audit_log');
SELECT has_table('cron_job_log');

-- 3. 投影视图关键列
SELECT has_column('users', 'id');
SELECT has_column('users', 'tenant_id');
SELECT has_column('users', 'username');
SELECT has_column('users', 'is_suspended');
SELECT has_column('users', 'updated_at');
SELECT has_column('tenants', 'id');
SELECT has_column('tenants', 'tenant_id');
SELECT has_column('tenants', 'name');
SELECT has_column('tenants', 'db_user');
SELECT has_column('organizations', 'id');
SELECT has_column('organizations', 'organization_id');
SELECT has_column('organizations', 'tenant_id');
SELECT has_column('organizations', 'name');
SELECT has_column('user_tenants', 'user_id');
SELECT has_column('user_tenants', 'tenant_id');
SELECT has_column('user_tenants', 'organization_id');
SELECT has_column('role', 'id');
SELECT has_column('role', 'tenant_id');
SELECT has_column('role', 'name');
SELECT has_column('role', 'role_code');
SELECT has_column('role', 'type');
SELECT has_column('tenant_role', 'id');
SELECT has_column('tenant_role', 'tenant_id');
SELECT has_column('tenant_role', 'name');
SELECT has_column('user_role', 'user_id');
SELECT has_column('user_role', 'tenant_id');
SELECT has_column('user_role', 'organization_id');
SELECT has_column('user_role', 'role_code');

-- 4. 自主表关键列（D26 + D27 双列）
SELECT has_column('iam_menu', 'menu_name');
SELECT has_column('iam_menu', 'parent_id');
SELECT has_column('iam_menu', 'api_url');
SELECT has_column('iam_menu', 'api_method');
SELECT has_column('iam_menu', 'is_affix');
SELECT has_column('iam_role_menu', 'role_id');
SELECT has_column('iam_role_menu', 'org_role_id');
SELECT has_column('iam_role_menu', 'menu_id');
SELECT has_column('iam_role_menu', 'tenant_id');
SELECT has_column('iam_role_menu', 'organization_id');
SELECT has_column('iam_role_data_scope', 'role_id');
SELECT has_column('iam_role_data_scope', 'org_role_id');
SELECT has_column('iam_role_data_scope', 'scope_type');
SELECT has_column('iam_role_data_scope', 'tenant_id');
SELECT has_column('iam_role_data_scope', 'organization_id');

-- 5. 业务表关键列
SELECT has_column('user_profile', 'user_id');
SELECT has_column('user_profile', 'tenant_id');
SELECT has_column('user_profile', 'organization_id');
SELECT has_column('user_profile', 'deleted_at');
SELECT has_column('department', 'tenant_id');
SELECT has_column('department', 'organization_id');
SELECT has_column('department', 'deleted_at');
SELECT has_column('app_config', 'config_key');
SELECT has_column('app_config', 'is_public');
SELECT has_column('app_config', 'tenant_id');
SELECT has_column('app_config', 'organization_id');
SELECT has_column('audit_log', 'tenant_id');
SELECT has_column('audit_log', 'organization_id');
SELECT has_column('audit_log', 'operation');

-- 6. 自主表索引（055 + D26 + D27）
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_menu' AND indexdef ILIKE '%idx_iam_menu_api_url_method%'),
    'iam_menu(api_url,api_method) 有部分唯一索引（055）');
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_menu' AND indexdef ILIKE '%idx_iam_menu_api_code%'),
    'iam_menu(api_code) 有索引（一码多端点，055）');
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_role_menu' AND indexdef ILIKE '%iam_role_menu_role_menu_key%'),
    'iam_role_menu(role_id,org_role_id,menu_id) 有唯一索引（D26）');
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_role_data_scope' AND indexdef ILIKE '%iam_role_data_scope_role_scope_key%'),
    'iam_role_data_scope(role_id,org_role_id,scope_type,dept_id) 有唯一索引（D26）');

-- 7. 跨 schema FK（D26/D27）
SELECT fk_ok('iam_role_menu', 'menu_id', 'iam_menu', 'id');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='user_profile_user_id_fkey') = 1, 'user_profile.user_id FK → public.users(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='user_profile_organization_id_fkey') = 1, 'user_profile.organization_id FK → public.organizations(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='user_position_user_id_fkey') = 1, 'user_position.user_id FK → public.users(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='user_position_organization_id_fkey') = 1, 'user_position.organization_id FK → public.organizations(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='iam_role_menu_role_id_fk') = 1, 'iam_role_menu.role_id FK → public.roles(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='iam_role_menu_org_role_id_fk') = 1, 'iam_role_menu.org_role_id FK → public.organization_roles(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='iam_role_data_scope_role_id_fk') = 1, 'iam_role_data_scope.role_id FK → public.roles(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='iam_role_data_scope_org_role_id_fk') = 1, 'iam_role_data_scope.org_role_id FK → public.organization_roles(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='user_profile_tenant_id_fk') = 1, 'user_profile.tenant_id FK → public.tenants(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='department_tenant_id_fk') = 1, 'department.tenant_id FK → public.tenants(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='department_organization_id_fk') = 1, 'department.organization_id FK → public.organizations(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='position_tenant_id_fk') = 1, 'position.tenant_id FK → public.tenants(id)');
SELECT ok((SELECT count(*) FROM pg_constraint WHERE conname='position_organization_id_fk') = 1, 'position.organization_id FK → public.organizations(id)');

-- 8. Casdoor 时代表已移除
SELECT hasnt_table('casdoor_user_mirror');
SELECT hasnt_table('sys_role');
SELECT hasnt_table('sys_user');
SELECT hasnt_table('sys_tenant');
SELECT hasnt_table('sys_user_session');
SELECT hasnt_table('sys_token_blacklist');
SELECT hasnt_table('sys_secret');
SELECT hasnt_table('sys_api');
SELECT hasnt_table('sys_menu');
SELECT hasnt_table('sys_user_legacy');

-- 9. 镜像表已退役（应无物理表）
SELECT hasnt_table('organization_role');
SELECT hasnt_table('user_role');

-- 10. API 暴露视图
SELECT ok((SELECT count(*) >= 1 FROM pg_views WHERE viewname='v_role_list' AND schemaname='api_v1_platform'), 'api_v1_platform.v_role_list 视图存在');
SELECT ok((SELECT count(*) >= 1 FROM pg_views WHERE viewname='users' AND schemaname='api_v1_platform'), 'api_v1_platform.users 视图存在');
SELECT ok((SELECT count(*) >= 1 FROM pg_views WHERE viewname='tenant_role' AND schemaname='api_v1_platform'), 'api_v1_platform.tenant_role 视图存在');
SELECT ok((SELECT count(*) >= 1 FROM pg_views WHERE viewname='tenants' AND schemaname='api_v1_platform'), 'api_v1_platform.tenants 视图存在');
SELECT ok((SELECT count(*) >= 1 FROM pg_views WHERE viewname='organizations' AND schemaname='api_v1_platform'), 'api_v1_platform.organizations 视图存在');
SELECT has_view('casbin_rule');
SELECT has_view('sys_user', 'platform.sys_user 兼容视图存在');

SELECT * FROM finish();
ROLLBACK;
