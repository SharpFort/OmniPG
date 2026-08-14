-- =============================================================================
-- 032_menu_type_link.sql — iam_menu_type 补充 link 值（统一外部链接/iframe）
-- =============================================================================
-- 背景: 2026-08-05 用户决策
--   menu_type 补充 'link' 统一"外部链接 + iframe 内嵌"两类场景
--   → 四值封闭（directory/menu/button/link），未来几乎不再变动
-- 关键坑（已规避）:
--   - ALTER TYPE ADD VALUE 无 IF NOT EXISTS → DO 块检查 + 动态执行（幂等）
--   - PG12+ 新值不能在同一事务内使用 → psql autocommit 逐语句提交，
--     验证 DO 块（独立事务）可安全使用 'link'
-- 联动:
--   - rpc_create_menu / rpc_update_menu 的 IN 校验加 'link'（否则前端传 link 被友好层拒绝）
--   - 类型/列注释更新
-- 语义: link 类型 = path 为 http(s):// 外部链接或 iframe 内嵌 URL；component 留空
-- 17 号文档归位登记（2026-08-14，§6.2 情形 a，P0-6）:
--   · ADD VALUE 'link' 段已删——枚举定义归 db/src/public/types/menu_type.sql
--     （四值权威：directory/menu/button/link，bootstrap 前置建类型）
--   · §1 rpc_create_menu/rpc_update_menu 8 参版已删（终态 057 18 参版在
--     db/api_v1/public/rpc/rpc_create_menu.sql / rpc_update_menu.sql）
--   · COMMENT ON TYPE 已删（随定义归 src/types/menu_type.sql；§5）
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §2 注释更新（列注释保留——表结构元数据）
-- ---------------------------------------------------------------------------
COMMENT ON COLUMN public.iam_menu.menu_type IS '菜单类型: directory(目录) / menu(菜单) / button(按钮) / link(外链或iframe，032)';

-- ---------------------------------------------------------------------------
-- §3 验证（link 值可用性；函数联动检查已随 §1 归位移除）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_link     int;
BEGIN
    SELECT count(*) INTO v_link FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'iam_menu_type' AND e.enumlabel = 'link';

    -- 新值可用性（psql autocommit 独立事务）
    IF 'link'::iam_menu_type IS NULL OR v_link <> 1 THEN
        RAISE EXCEPTION '032 验证失败: link 值不可用';
    END IF;
    RAISE NOTICE '032: link 值=%（期望1） — 全部验证通过', v_link;
END $$;
