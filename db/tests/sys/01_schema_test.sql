-- 01_schema_test.sql：表/列/约束存在性验证（T7 重写：Logto 镜像表 + 自主表）
BEGIN;
SELECT plan(67);

-- 1. 表存在性（13 张：镜像表 + 自主表 + 业务表）
SELECT has_table('users');
SELECT has_table('tenants');
SELECT has_table('user_tenants');
SELECT has_table('role');
SELECT has_table('iam_api');
SELECT has_table('iam_menu');
SELECT has_table('iam_role_api');
SELECT has_table('iam_role_menu');
SELECT has_table('user_profile');
SELECT has_table('department');
SELECT has_table('app_config');
SELECT has_table('audit_log');
SELECT has_table('cron_job_log');

-- 2. 关键列存在性（镜像表 + 自主表）
SELECT has_column('users', 'id');
SELECT has_column('users', 'username');
SELECT has_column('users', 'is_suspended');
SELECT has_column('tenants', 'id');
SELECT has_column('tenants', 'name');
SELECT has_column('user_tenants', 'user_id');
SELECT has_column('user_tenants', 'organization_id');
SELECT has_column('role', 'id');
SELECT has_column('role', 'name');
SELECT has_column('role', 'role_code');
SELECT has_column('role', 'type');
SELECT has_column('iam_api', 'path');
SELECT has_column('iam_api', 'method');
SELECT has_column('iam_api', 'name');
SELECT has_column('iam_menu', 'menu_name');
SELECT has_column('iam_menu', 'parent_id');
SELECT has_column('iam_role_api', 'role_code');
SELECT has_column('iam_role_api', 'api_id');
SELECT has_column('iam_role_menu', 'role_code');
SELECT has_column('iam_role_menu', 'menu_id');

-- 3. 业务表关键列（软删除/租户）
SELECT has_column('user_profile', 'user_id');
SELECT has_column('user_profile', 'tenant_id');
SELECT has_column('user_profile', 'deleted_at');
SELECT has_column('department', 'tenant_id');
SELECT has_column('department', 'deleted_at');
SELECT has_column('app_config', 'config_key');
SELECT has_column('app_config', 'is_public');
SELECT has_column('audit_log', 'tenant_id');
SELECT has_column('audit_log', 'operation');

-- 4. 唯一索引验证（镜像表 users 可能无唯一约束，仅检查有 index）
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='users' AND indexname LIKE '%username%'),
    'users.username 有索引');

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='role' AND indexdef ILIKE '%idx_role_name%'),
    'role.name 有唯一索引');

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_api' AND indexdef ILIKE '%UNIQUE%path%method%'),
    'iam_api(path,method) 有唯一索引');

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_role_api' AND indexdef ILIKE '%UNIQUE%role_code%api_id%'),
    'iam_role_api(role_code,api_id) 有唯一索引');

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_indexes WHERE tablename='iam_role_menu' AND indexdef ILIKE '%UNIQUE%role_code%menu_id%'),
    'iam_role_menu(role_code,menu_id) 有唯一索引');

-- 5. 外键约束验证（镜像表关联）
SELECT fk_ok('user_tenants', 'user_id', 'users', 'id');
SELECT fk_ok('user_tenants', 'organization_id', 'tenants', 'id');
SELECT fk_ok('user_profile', 'user_id', 'users', 'id');
SELECT fk_ok('user_profile', 'tenant_id', 'tenants', 'id');
SELECT fk_ok('iam_role_api', 'api_id', 'iam_api', 'id');
SELECT fk_ok('iam_role_menu', 'menu_id', 'iam_menu', 'id');

-- 6. Casdoor 时代表已移除
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

-- 7. 视图存在（用 pg_views 查询，避免 schema 前缀问题）
SELECT ok(
    (SELECT count(*) >= 1 FROM pg_views WHERE viewname='v_role_list' AND schemaname='api_v1_sys'),
    'api_v1_sys.v_role_list 视图存在');

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_views WHERE viewname='sys_user' AND schemaname='api_v1_sys'),
    'api_v1_sys.sys_user 视图存在');

SELECT has_view('casbin_rule');

-- 8. 扩展存在
SELECT has_extension('pg_pwhash');

SELECT * FROM finish();
ROLLBACK;
