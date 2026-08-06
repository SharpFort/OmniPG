-- =============================================================================
-- 022_iam_menu_btn_fields.sql — iam_menu 按钮级字段（05.2 §4.2 拍板）
-- =============================================================================
-- 背景: 2026-08-04 用户拍板（05.2 决策）
--   iam_menu 增加菜单类型（目录/菜单/按钮）+ 权限码 + 组件路径 + 显隐
--   对照 RuoYi sys_menu（menu_type/perms/component/visible，源码已核实）
-- 配套:
--   - 按钮级权限: has_permission(perms)（P0 缺口，05.2 §2.1，待 023 实现）
--   - 管理端写 Logto 路径: 放弃（05.2 §4.1 决策：Logto Console 管理 + webhook 同步）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_menu 加列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_menu
    ADD COLUMN IF NOT EXISTS menu_type  text NOT NULL DEFAULT 'menu',
    ADD COLUMN IF NOT EXISTS perms      text,
    ADD COLUMN IF NOT EXISTS component  text,
    ADD COLUMN IF NOT EXISTS is_visible boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.iam_menu.menu_type IS '菜单类型: directory(目录) / menu(菜单) / button(按钮)';
COMMENT ON COLUMN public.iam_menu.perms IS '权限码（如 sys:user:delete；按钮级权限经 has_permission(perms) 判定，对应 iam_api.api_code）';
COMMENT ON COLUMN public.iam_menu.component IS '前端组件路径（路由渲染，仅 menu 类型使用）';
COMMENT ON COLUMN public.iam_menu.is_visible IS '是否显示（目录/菜单显隐控制）';

CREATE INDEX IF NOT EXISTS idx_iam_menu_type ON public.iam_menu(menu_type);

-- ---------------------------------------------------------------------------
-- §2 重建暴露视图（含新列）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_menu CASCADE;
CREATE VIEW api_v1_sys.sys_menu AS
SELECT id, parent_id, menu_name, menu_type, perms, path, component, icon,
       order_num, is_active, is_visible, created_at, updated_at, created_by, updated_by
FROM iam_menu;
COMMENT ON VIEW api_v1_sys.sys_menu IS '菜单视图（含按钮级字段：menu_type/perms/component/is_visible）';

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cols int;
BEGIN
    SELECT count(*) INTO v_cols
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu'
      AND column_name IN ('menu_type','perms','component','is_visible');
    RAISE NOTICE '022: iam_menu 新列=%（期望 4）', v_cols;
END $$;
