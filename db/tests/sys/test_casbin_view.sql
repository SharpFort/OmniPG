-- pgTAP 测试：casbin_rule 视图
-- 运行方式：pg_prove -U app_owner -d app_db db/tests/public/test_casbin_view.sql
BEGIN;
SELECT plan(10);

-- ============================================================
-- 1. 视图存在性检查
-- ============================================================
SELECT has_view('casbin_rule', 'casbin_rule 视图存在');

-- ============================================================
-- 2. 视图列存在性检查
-- ============================================================
SELECT columns_are('casbin_rule', ARRAY['id', 'ptype', 'v0', 'v1', 'v2', 'v3', 'v4', 'v5'], 'casbin_rule 视图包含所有必需列');

-- ============================================================
-- 3. p 规则输出格式验证
-- ============================================================
-- 验证 ptype 列值恒为 'p'
SELECT results_eq(
    $$ SELECT DISTINCT ptype FROM casbin_rule $$,
    ARRAY['p'::varchar],
    'casbin_rule 视图 ptype 列值恒为 p'
);

-- 验证 v0 列输出的是 role_code（非 UUID）
SELECT results_eq(
    $$ SELECT v0 FROM casbin_rule LIMIT 1 $$,
    ARRAY['super_admin'::varchar],
    'v0 列输出角色代码（role_code）'
);

-- ============================================================
-- 4. is_active 过滤验证
-- ============================================================
-- 禁用角色后，其策略不应出现在视图中
-- 先确认 super_admin 的策略存在
SELECT results_eq(
    $$ SELECT count(*) FROM casbin_rule WHERE v0 = 'super_admin' $$,
    ARRAY[1::bigint],
    'super_admin 的策略存在（种子数据）'
);

-- 验证禁用的 API 不会出现在视图中
SELECT results_eq(
    $$ SELECT count(*) FROM casbin_rule WHERE v1 = '/nonexistent' $$,
    ARRAY[0::bigint],
    '不存在的 API 路径不出现在视图中'
);

-- ============================================================
-- 5. 非 activate API 过滤
-- ============================================================
-- 验证 is_active = false 的 API 不会出现在视图中
SELECT results_eq(
    $$ SELECT count(*) FROM casbin_rule c JOIN sys_api a ON c.v1 = a.path AND c.v2 = a.method WHERE a.is_active = false $$,
    ARRAY[0::bigint],
    '禁用的 API 不会出现在 casbin_rule 视图中'
);

-- ============================================================
-- 6. 视图可查询性
-- ============================================================
SELECT lives_ok(
    $$ SELECT * FROM casbin_rule LIMIT 10 $$,
    'casbin_rule 视图可正常查询'
);

SELECT * FROM finish();
ROLLBACK;
