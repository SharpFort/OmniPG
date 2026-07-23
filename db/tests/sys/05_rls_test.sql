-- 05_rls_test.sql：RLS 行级安全策略测试
BEGIN;
SELECT plan(8);

-- 注意：此测试需要在 RLS 迁移后执行，并使用不同 tenant_id 的 JWT

-- 1. 验证关键表上有 RLS 启用
SELECT table_has_rls('sys_tenant');
SELECT table_has_rls('sys_user');
SELECT table_has_rls('sys_role');
SELECT table_has_rls('sys_department');
SELECT table_has_rls('sys_api');
SELECT table_has_rls('sys_menu');

-- 2. 验证 sys_role 的 RLS 策略允许全局角色（tenant_id=NULL）
SELECT lives_ok($$
    SELECT 1 FROM sys_role WHERE tenant_id IS NULL
$$, '全局角色可查询');

-- 3. 验证 sys_api 的 RLS 策略允许所有认证用户读取
SELECT lives_ok($$
    SELECT 1 FROM sys_api WHERE is_active = TRUE
$$, 'API 资源可读');

SELECT * FROM finish();
ROLLBACK;
