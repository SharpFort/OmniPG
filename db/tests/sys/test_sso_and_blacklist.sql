-- pgTAP 测试：SSO 登录 + Token 黑名单
-- 运行方式：pg_prove -U app_owner -d app_db db/tests/public/test_sso_and_blacklist.sql
BEGIN;
SELECT plan(10);

-- ============================================================
-- 1. 表存在性检查
-- ============================================================
SELECT has_table('sys_user', '用户表 sys_user 存在');
SELECT has_table('sys_user_session', '会话表 sys_user_session 存在');
SELECT has_table('sys_token_blacklist', '黑名单表 sys_token_blacklist 存在');
SELECT has_table('sys_role', '角色表 sys_role 存在');

-- ============================================================
-- 2. 函数存在性检查
-- ============================================================
SELECT has_function('user_login_sso', ARRAY['text', 'text'], '登录函数 user_login_sso(text, text) 存在');
SELECT has_function('check_token_blacklist', ARRAY[], '黑名单检查函数 check_token_blacklist() 存在');
SELECT has_function('refresh_token_rtr', ARRAY['text'], '刷新函数 refresh_token_rtr(text) 存在');

-- ============================================================
-- 3. 登录成功/失败
-- ============================================================
-- 使用种子数据 admin/admin123 验证登录成功
SELECT lives_ok(
    $$ SELECT user_login_sso('admin', 'admin123') $$,
    'admin 登录成功（密码正确）'
);

-- 验证错误密码抛出异常
SELECT throws_ok(
    $$ SELECT user_login_sso('admin', 'wrongpassword') $$,
    'P0001',
    'Invalid Credentials',
    '错误密码抛出 P0001 Invalid Credentials'
);

-- ============================================================
-- 4. 黑名单检查逻辑
-- ============================================================
-- 验证 check_token_blacklist 在无 JWT 上下文时不抛出异常（匿名访问）
SELECT lives_ok(
    $$ SELECT check_token_blacklist() $$,
    'check_token_blacklist 在无 JWT 上下文时不抛出异常'
);

SELECT * FROM finish();
ROLLBACK;
