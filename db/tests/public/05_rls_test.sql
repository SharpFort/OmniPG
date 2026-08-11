-- 05_rls_test.sql：RLS 行级安全策略测试（T7 重写：Logto 镜像表 + 自主表）
BEGIN;
SELECT plan(12);

-- 1. 验证关键表上有 RLS 启用（用 pg_class 查询，bigint cast）
SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'users' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'users RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'tenants' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'tenants RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'user_tenants' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'user_tenants RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'role' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'role RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'user_profile' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'user_profile RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'department' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'department RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_api' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'iam_api RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_menu' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'iam_menu RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_role_api' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'iam_role_api RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_role_menu' AND n.nspname = 'public' AND c.relrowsecurity = true),
    1::bigint, 'iam_role_menu RLS 已启用');

-- role 镜像表全局可读
SELECT lives_ok($$
    SELECT 1 FROM role LIMIT 1
$$, 'role 镜像表可读');

-- iam_api 策略允许读取激活项
SELECT lives_ok($$
    SELECT 1 FROM iam_api WHERE is_active = TRUE LIMIT 1
$$, 'iam_api 激活项可读');

SELECT * FROM finish();
ROLLBACK;
