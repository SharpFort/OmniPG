-- =============================================================================
-- 055-T1 前置核查.sql — 菜单权限单表化（055）T1 数据迁移前置核查（只读）
-- =============================================================================
-- 用途: 在存量库（WSL Pigsty app_db）执行，输出 T1 数据迁移所需的全部现状数据
-- 执行: psql -U app_owner -d app_db -f scripts/055-t1-precheck.sql
-- 对应: docs/开发实施方案/16-055-T1前置核查-存量数据清单.md
-- 只读: 本脚本仅 SELECT，无任何写操作
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 总览（一行看全貌）
-- ---------------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM iam_api)                                 AS api_total,
    (SELECT count(*) FROM iam_api WHERE api_code IS NOT NULL)      AS api_with_code,
    (SELECT count(*) FROM iam_api WHERE api_code IS NULL)          AS api_no_code,
    (SELECT count(*) FROM iam_api WHERE menu_id IS NULL)           AS api_orphan,
    (SELECT count(*) FROM iam_menu WHERE menu_type = 'button')     AS menu_buttons,
    (SELECT count(*) FROM iam_menu WHERE menu_type = 'button'
        AND api_code IS NULL)                                      AS button_no_code,
    (SELECT count(*) FROM iam_role_api)                            AS role_api_bindings;

-- ---------------------------------------------------------------------------
-- §1 iam_api 全表清单（现状全量，带归属菜单名）
-- ---------------------------------------------------------------------------
SELECT a.id, a.path, a.method, a.name, a.api_code, a.api_group,
       m.menu_name AS belong_menu, a.is_active, a.created_at
FROM iam_api a LEFT JOIN iam_menu m ON m.id = a.menu_id
ORDER BY (a.api_code IS NULL), a.api_group, a.path, a.method;

-- ---------------------------------------------------------------------------
-- §2 无码行清单（D9 清除对象）
-- ---------------------------------------------------------------------------
SELECT path, method, name, api_group, is_active
FROM iam_api WHERE api_code IS NULL
ORDER BY path, method;

-- ---------------------------------------------------------------------------
-- §3 有码行清单（D9 转换对象，含 role_api 绑定数）
-- ---------------------------------------------------------------------------
SELECT a.api_code, a.path, a.method, a.name, a.api_group,
       count(ra.id) AS role_bindings
FROM iam_api a
LEFT JOIN iam_role_api ra ON ra.api_id = a.id
WHERE a.api_code IS NOT NULL
GROUP BY a.id
ORDER BY a.api_code;

-- ---------------------------------------------------------------------------
-- §4 死端点判定（PostgREST 实际暴露 = api_v1_public 视图/RPC）
--    DEAD = 仓库/存量库均无对应暴露 → D9 清除对象
-- ---------------------------------------------------------------------------
WITH exposed AS (
    SELECT '/rpc/' || p.proname AS path
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname LIKE 'rpc_%'
    UNION
    SELECT '/' || v.table_name
    FROM information_schema.views v
    WHERE v.table_schema = 'api_v1_public'
)
SELECT a.path, a.method, a.name, a.api_code,
       CASE WHEN e.path IS NULL THEN 'DEAD' ELSE 'ALIVE' END AS endpoint_status
FROM iam_api a LEFT JOIN exposed e ON e.path = a.path
ORDER BY endpoint_status, a.path, a.method;

-- ---------------------------------------------------------------------------
-- §5 button 行挂接数核查（>1 为冲突清单，T1 转换须逐行映射不合并）
-- ---------------------------------------------------------------------------
SELECT m.id, m.menu_name, m.api_code, m.parent_id, count(a.id) AS api_rows
FROM iam_menu m
LEFT JOIN iam_api a ON a.menu_id = m.id
WHERE m.menu_type = 'button'
GROUP BY m.id
ORDER BY api_rows DESC, m.menu_name;

-- ---------------------------------------------------------------------------
-- §6 孤儿行清单（menu_id IS NULL，D9 一并清除）
-- ---------------------------------------------------------------------------
SELECT path, method, name, api_code
FROM iam_api WHERE menu_id IS NULL
ORDER BY path, method;

-- ---------------------------------------------------------------------------
-- §7 role_api 绑定分布（有码/无码行上的绑定数；无码行绑定随 D9 清除）
-- ---------------------------------------------------------------------------
SELECT CASE WHEN a.api_code IS NULL THEN 'NO_CODE' ELSE 'WITH_CODE' END AS code_state,
       count(ra.id) AS bindings
FROM iam_role_api ra JOIN iam_api a ON a.id = ra.api_id
GROUP BY 1;

-- 无码行上的绑定明细（清除影响面）
SELECT ra.role_code, a.path, a.method, a.api_code
FROM iam_role_api ra JOIN iam_api a ON a.id = ra.api_id
WHERE a.api_code IS NULL
ORDER BY ra.role_code, a.path;

-- ---------------------------------------------------------------------------
-- §8 一码多行核查（023 部分唯一索引下应为 0；>0 需逐行确认）
-- ---------------------------------------------------------------------------
SELECT api_code, count(*) AS rows_cnt
FROM iam_api WHERE api_code IS NOT NULL
GROUP BY api_code HAVING count(*) > 1;

-- ---------------------------------------------------------------------------
-- §9 菜单树 button 全量（055 转换目标载体）
-- ---------------------------------------------------------------------------
SELECT m.id, m.menu_name, m.api_code, m.parent_id, p.menu_name AS parent_name, m.is_active
FROM iam_menu m LEFT JOIN iam_menu p ON p.id = m.parent_id
WHERE m.menu_type = 'button'
ORDER BY m.parent_id, m.order_num;

-- ---------------------------------------------------------------------------
-- §10 转换映射预期
--  10.1 有码行但无同码 button 行 → 需新建 button 行（T1 规则 2）
-- ---------------------------------------------------------------------------
SELECT a.api_code, a.path, a.method, a.name, a.menu_id
FROM iam_api a
WHERE a.api_code IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM iam_menu m
                  WHERE m.menu_type = 'button' AND m.api_code = a.api_code)
ORDER BY a.api_code;

--  10.2 有码行且有同码 button 行 → 回填 api_url/api_method（T1 规则 1）
SELECT a.api_code, a.path, a.method, b.menu_name AS button_name, b.id AS button_id
FROM iam_api a
JOIN iam_menu b ON b.menu_type = 'button' AND b.api_code = a.api_code
ORDER BY a.api_code;

-- ---------------------------------------------------------------------------
-- §11 历史迁移 NOTICE 对照（040/043 验证块记录的时点事实）
--   040: button 空 api_code = 0（040 时点全部按钮有码）
--   043: api_code IS NULL 行 ≈14（043 时点实测）
-- ---------------------------------------------------------------------------
SELECT '040' AS mig, 'button 空 api_code = 0（040 验证块断言）' AS fact
UNION ALL SELECT '043', 'api_code IS NULL ≈14 行（043 头注实测，055 实施时以 §2 实测为准';
