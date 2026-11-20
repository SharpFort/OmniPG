-- pgTAP 测试：casbin_rule 视图（T7 重写：Logto 自主表投影）
-- 运行方式：pg_prove -U app_owner -d app_db db/tests/platform/test_casbin_view.sql
BEGIN;
SELECT plan(8);

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
-- 2026-11-20 阶段3修正：原断言 `LIMIT 1` 无 ORDER BY——依赖视图行序（UNION 去重 +
-- 父级目录绑定回填后行序变化即失败）。改为全体行"非 UUID 形态"校验（顺序无关；
-- Logto 自动生成的数字开头角色名如 14eqvuyw… 亦为合法 role_code，不受影响；
-- 空集恒真由下一条用例的 role_super_admin 存在性断言兜底）
SELECT results_eq(
    $$ SELECT COALESCE(bool_and(v0 !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'), true)
         FROM casbin_rule WHERE v0 IS NOT NULL $$,
    ARRAY[true]::boolean[],
    'v0 列输出角色代码（role_code，非 UUID）'
);

-- ============================================================
-- 4. is_active 过滤验证
-- ============================================================
-- 确认 role_super_admin 的策略存在（种子数据）
SELECT results_eq(
    $$ SELECT count(*) > 0 FROM casbin_rule WHERE v0 = 'role_super_admin' $$,
    ARRAY[true],
    'role_super_admin 的策略存在（种子数据）'
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
-- 055 单表化：API 段数据源 = iam_role_menu → iam_menu（button 行 api_url/api_method）
SELECT results_eq(
    $$ SELECT count(*) FROM casbin_rule c JOIN iam_menu m ON c.v1 = m.api_url AND c.v2 = m.api_method WHERE m.is_active = false $$,
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
