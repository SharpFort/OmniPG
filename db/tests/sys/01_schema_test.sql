-- 01_schema_test.sql：表/列/约束存在性验证
BEGIN;
SELECT plan(58);

-- 1. 表存在性（14 张表）
SELECT has_table('sys_tenant');
SELECT has_table('sys_secret');
SELECT has_table('sys_department');
SELECT has_table('sys_user');
SELECT has_table('sys_role');
SELECT has_table('sys_api');
SELECT has_table('sys_menu');
SELECT has_table('sys_user_role');
SELECT has_table('sys_role_api');
SELECT has_table('sys_role_menu');
SELECT has_table('sys_user_session');
SELECT has_table('sys_token_blacklist');
SELECT has_table('sys_user_role_request');
SELECT has_table('sys_audit_log');
SELECT has_table('sys_cron_log');

-- 2. 关键列存在性（含软删除字段）
SELECT has_column('sys_tenant', 'tenant_code');
SELECT has_column('sys_tenant', 'status');
SELECT has_column('sys_user', 'deleted_at');
SELECT has_column('sys_user', 'tenant_id');
SELECT has_column('sys_role', 'tenant_id');
SELECT has_column('sys_role', 'deleted_at');
SELECT has_column('sys_department', 'tenant_id');
SELECT has_column('sys_department', 'deleted_at');
SELECT has_column('sys_api', 'deleted_at');
SELECT has_column('sys_menu', 'deleted_at');
SELECT has_column('sys_menu', 'is_active');

-- 6. 审计 _by 字段存在性
SELECT has_column('sys_tenant', 'created_by');
SELECT has_column('sys_tenant', 'updated_by');
SELECT has_column('sys_tenant', 'deleted_by');
SELECT has_column('sys_user', 'created_by');
SELECT has_column('sys_user', 'updated_by');
SELECT has_column('sys_user', 'deleted_by');
SELECT has_column('sys_role', 'created_by');
SELECT has_column('sys_role', 'updated_by');
SELECT has_column('sys_role', 'deleted_by');
SELECT has_column('sys_department', 'created_by');
SELECT has_column('sys_department', 'updated_by');
SELECT has_column('sys_department', 'deleted_by');
SELECT has_column('sys_api', 'created_by');
SELECT has_column('sys_api', 'updated_by');
SELECT has_column('sys_api', 'deleted_by');
SELECT has_column('sys_menu', 'created_by');
SELECT has_column('sys_menu', 'updated_by');
SELECT has_column('sys_menu', 'deleted_by');

-- 3. 唯一约束验证
SELECT col_is_unique('sys_user', 'username');
SELECT col_is_unique('sys_user_session', 'refresh_token_hash');
SELECT col_is_unique('sys_api', ARRAY['path', 'method']);
SELECT col_is_unique('sys_tenant', 'tenant_code');

-- 4. 外键约束验证
SELECT fk_ok('sys_user', 'tenant_id', 'sys_tenant', 'id');
SELECT fk_ok('sys_department', 'tenant_id', 'sys_tenant', 'id');
SELECT fk_ok('sys_user', 'dept_id', 'sys_department', 'id');
SELECT fk_ok('sys_user_role', 'user_id', 'sys_user', 'id');
SELECT fk_ok('sys_user_role', 'role_id', 'sys_role', 'id');
SELECT fk_ok('sys_role_api', 'role_id', 'sys_role', 'id');
SELECT fk_ok('sys_role_api', 'api_id', 'sys_api', 'id');

-- 5. casbin_rule 视图存在
SELECT has_view('casbin_rule');

-- 6. 扩展存在
SELECT has_extension('pg_pwhash');

SELECT * FROM finish();
ROLLBACK;
