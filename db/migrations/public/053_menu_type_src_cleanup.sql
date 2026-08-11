-- =============================================================================
-- 053_menu_type_src_cleanup.sql — 清理孤儿类型 public.menu_type
-- =============================================================================
-- 背景（2026-08-11 查证）:
--   db/src/public/types/menu_type.sql 定义 public.menu_type('DIR','MENU','BUTTON')
--   （大写三值，T7 时代来源文件），但 iam_menu.menu_type 列实际使用的是
--   031/032 迁移定义的 iam_menu_type（directory/menu/button/link，小写四值）。
--   public.menu_type 全仓无任何表/函数/视图引用（仅自身定义），
--   apply-src 历史应用可能在存量库残留该无用类型 → 本迁移清理。
--   源文件已随本迁移同步删除（apply-src 不再重建）。
-- 注意: iam_menu_type（031/032，含 link）不受影响。
-- 依赖: 无（DROP TYPE IF EXISTS + CASCADE 幂等，无使用者时 CASCADE 无副作用）。

DROP TYPE IF EXISTS public.menu_type CASCADE;
