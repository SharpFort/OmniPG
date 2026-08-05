-- pgTAP 测试：多租户 RLS 穿透测试（T7 重写：Logto 镜像表）
-- 运行方式：pg_prove -U app_owner -d app_db db/tests/sys/test_rls_isolation.sql
BEGIN;
SELECT plan(14);

-- ============================================================
-- 1. 镜像表存在性 + RLS 策略
-- ============================================================
SELECT has_table('users', '用户镜像表 users 存在');
SELECT has_table('tenants', '租户镜像表 tenants 存在');
SELECT has_table('user_tenants', '成员镜像表 user_tenants 存在');
SELECT has_table('role', '角色镜像表 role 存在');

-- ============================================================
-- 2. RLS 策略存在性
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'users' AND schemaname = 'public' $$,
    ARRAY[1::bigint],
    'users 表有 1 个 RLS 策略（users_tenant_policy）'
);

SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'user_tenants' AND policyname = 'user_tenants_policy' $$,
    ARRAY[1::bigint],
    'user_tenants_policy 策略存在'
);

SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'user_profile' AND policyname = 'profile_tenant_policy' $$,
    ARRAY[1::bigint],
    'profile_tenant_policy 策略存在'
);

-- ============================================================
-- 3. RLS 启用状态验证
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'users' AND n.nspname = 'public' AND c.relrowsecurity = true $$,
    ARRAY[1::bigint],
    'users 表已启用 RLS'
);

SELECT results_eq(
    $$ SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'role' AND n.nspname = 'public' AND c.relrowsecurity = true $$,
    ARRAY[1::bigint],
    'role 表已启用 RLS'
);

-- ============================================================
-- 4. 辅助函数存在性（Logto claims 语义）
-- ============================================================
SELECT has_function('current_user_id', ARRAY[]::text[], 'current_user_id() 函数存在');
SELECT has_function('current_tenant_id', ARRAY[]::text[], 'current_tenant_id() 函数存在');
SELECT has_function('current_user_roles', ARRAY[]::text[], 'current_user_roles() 函数存在');
SELECT has_function('is_super_admin', ARRAY[]::text[], 'is_super_admin() 函数存在');

-- ============================================================
-- 5. RLS helper 返回类型（text / text[] — Logto nanoid）
-- ============================================================
SELECT ok(
    (SELECT data_type = 'text' FROM information_schema.routines
     WHERE routine_name = 'current_tenant_id' AND specific_schema = 'public'),
    'current_tenant_id 返回 text（Logto organization_id）'
);

SELECT * FROM finish();
ROLLBACK;
