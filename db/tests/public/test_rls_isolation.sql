-- pgTAP 测试：多租户 RLS 穿透测试
-- 运行方式：pg_prove -U app_owner -d app_db db/tests/public/test_rls_isolation.sql
BEGIN;
SELECT plan(10);

-- ============================================================
-- 1. RLS 策略存在性检查
-- ============================================================
SELECT has_table('sys_user', '用户表 sys_user 存在');

-- 验证 RLS 策略存在
SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'sys_user' AND schemaname = 'public' $$,
    ARRAY[2::bigint],
    'sys_user 表有 2 个 RLS 策略（tenant_isolation + dept_isolation）'
);

-- ============================================================
-- 2. tenant_isolation_strict_policy 验证
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'sys_user' AND policyname = 'tenant_isolation_strict_policy' $$,
    ARRAY[1::bigint],
    'tenant_isolation_strict_policy 策略存在'
);

-- ============================================================
-- 3. 部门隔离验证
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'sys_user' AND policyname = 'employee_dept_isolation_policy' $$,
    ARRAY[1::bigint],
    'employee_dept_isolation_policy 策略存在'
);

-- ============================================================
-- 4. RLS 启用状态验证
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'sys_user' AND n.nspname = 'public' AND c.relrowsecurity = true $$,
    ARRAY[1::bigint],
    'sys_user 表已启用 RLS'
);

-- ============================================================
-- 5. 其他表 RLS 启用状态
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'sys_role' AND n.nspname = 'public' AND c.relrowsecurity = true $$,
    ARRAY[1::bigint],
    'sys_role 表已启用 RLS'
);

SELECT results_eq(
    $$ SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'sys_api' AND n.nspname = 'public' AND c.relrowsecurity = true $$,
    ARRAY[1::bigint],
    'sys_api 表已启用 RLS'
);

-- ============================================================
-- 6. 辅助函数存在性
-- ============================================================
SELECT has_function('current_user_id', ARRAY[], 'current_user_id() 函数存在');
SELECT has_function('current_tenant_id', ARRAY[], 'current_tenant_id() 函数存在');
SELECT has_function('current_user_dept_id', ARRAY[], 'current_user_dept_id() 函数存在');

-- ============================================================
-- 7. sys_token_blacklist 的 RESTRICTIVE 策略
-- ============================================================
SELECT results_eq(
    $$ SELECT count(*) FROM pg_policies WHERE tablename = 'sys_token_blacklist' AND policyname = 'blacklist_internal' $$,
    ARRAY[1::bigint],
    'sys_token_blacklist 有 RESTRICTIVE 策略阻止直接访问'
);

SELECT * FROM finish();
ROLLBACK;
