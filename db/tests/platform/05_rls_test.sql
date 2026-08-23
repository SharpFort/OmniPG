-- 05_rls_test.sql：RLS 行级安全策略测试（D25：镜像表退役，仅业务自主表）
BEGIN;
SELECT plan(8);

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'user_profile' AND n.nspname = 'platform' AND c.relrowsecurity = true),
    1::bigint, 'user_profile RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'department' AND n.nspname = 'platform' AND c.relrowsecurity = true),
    1::bigint, 'department RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_menu' AND n.nspname = 'platform' AND c.relrowsecurity = true),
    1::bigint, 'iam_menu RLS 已启用');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_api' AND n.nspname = 'platform'),
    0::bigint, 'iam_api 已删除（055 单表化）');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_role_api' AND n.nspname = 'platform'),
    0::bigint, 'iam_role_api 已删除（055 单表化）');

SELECT is(
    (SELECT count(*)::bigint FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
     WHERE c.relname = 'iam_role_menu' AND n.nspname = 'platform' AND c.relrowsecurity = true),
    1::bigint, 'iam_role_menu RLS 已启用');

-- D25: platform.role 是只读投影视图（可读）
SELECT lives_ok($$
    SELECT 1 FROM platform.role LIMIT 1
$$, 'platform.role 投影视图可读');

SELECT lives_ok($$
    SELECT 1 FROM iam_menu WHERE api_url IS NOT NULL LIMIT 1
$$, 'iam_menu 端点按钮行可读');

SELECT * FROM finish();
ROLLBACK;
