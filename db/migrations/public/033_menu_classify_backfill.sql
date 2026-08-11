-- =============================================================================
-- 033_menu_classify_backfill.sql — 菜单分类回填（前端联调 P1）
-- =============================================================================
-- 背景: 2026-08-05 前端联调反馈 #5 + 用户拍板
--   011 种子（022 加列前）→ menu_type 全为默认 'menu'，component 全空
--   本迁移按通用规则回填（不依赖具体数据，幂等重算）:
--   menu_type 分类规则（顺序即优先级）:
--     ① path 为 http(s)://     → 'link'（外链/iframe，032 新值）
--     ② 存在子节点             → 'directory'（目录）
--     ③ menu_name 动作词后缀   → 'button'（按钮：Add/Edit/Delete/Query/Export/
--                                   Import/Reset/Assign/Status/Remove/Detail/Pwd
--                                   + 中文 新增/编辑/删除/查询/导出/导入/重置/
--                                     分配/状态/移除/详情/密码，中英 12 对对齐）
--     ④ 其余                   → 'menu'
--   component 回填（仅 menu 类型，Vue 懒加载惯例）:
--     path=/system/user → component=system/user/index
--   perms 说明: 按钮权限码（对应 iam_api.api_code）由管理端 UI 配置
--     （sys:menu:update + iam_menu.perms），本迁移不臆造权限码
-- 幂等: UPDATE 规则重算可重复执行
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 menu_type 分类回填（规则重算，幂等）
-- ---------------------------------------------------------------------------
UPDATE iam_menu SET menu_type = CASE
    WHEN path LIKE 'http://%' OR path LIKE 'https://%' THEN 'link'::iam_menu_type
    WHEN EXISTS (SELECT 1 FROM iam_menu c WHERE c.parent_id = iam_menu.id)
        THEN 'directory'::iam_menu_type
    WHEN menu_name ~ '(Add|Edit|Delete|Query|Export|Import|Reset|Assign|Status|Remove|Detail|Pwd)$'
        OR menu_name ~ '(新增|编辑|删除|查询|导出|导入|重置|分配|状态|移除|详情|密码)$'
        THEN 'button'::iam_menu_type
    ELSE 'menu'::iam_menu_type
END
WHERE menu_type = 'menu'::iam_menu_type
   OR path LIKE 'http://%' OR path LIKE 'https://%';

-- ---------------------------------------------------------------------------
-- §2 component 回填（仅 menu 类型：path → 组件路径）
-- ---------------------------------------------------------------------------
UPDATE iam_menu SET component = regexp_replace(path, '^/', '') || '/index'
WHERE menu_type = 'menu'::iam_menu_type
  AND component IS NULL
  AND path IS NOT NULL AND path <> ''
  AND path NOT LIKE 'http://%' AND path NOT LIKE 'https://%';

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_null   int;
    v_total  int;
    v_dist   text;
BEGIN
    SELECT count(*), string_agg(menu_type::text || '=' || cnt, ', ' ORDER BY menu_type::text)
      INTO v_total, v_dist
    FROM (
        SELECT menu_type, count(*) AS cnt FROM iam_menu GROUP BY menu_type
    ) x;

    SELECT count(*) INTO v_null FROM iam_menu WHERE menu_type IS NULL;

    RAISE NOTICE '033: 菜单总数=% 分布=[%] NULL=%（期望0）', v_total, v_dist, v_null;

    IF v_null <> 0 THEN
        RAISE EXCEPTION '033 验证失败: 存在 NULL menu_type';
    END IF;
    RAISE NOTICE '033: 分类回填完成';
END $$;
