-- db/src/platform/types/scope_type.sql
-- 语义: 角色数据范围（RLS 部门维度过滤判定源；与 RuoYi DataScope 对齐）
--       使用位置: iam_role_data_scope.scope_type（042 建表 → 059 转原生 ENUM）
-- 演进史: v1 四值（2026-08-09 042 决策 D2：all/dept_and_child/self/custom）
--   → 2026-08-14 P0-8 由 TEXT+CHECK 转原生 ENUM（17 号文档 §8.2 存量清零）
-- 废弃值: 无（值只增不删；废弃用 z_deprecated_* 前缀 RENAME VALUE，永不删除）
-- 排序语义: all=1 / dept_and_child=4 / self=5 / custom=2（RuoYi DataScope 编号对齐）

-- ① 当前态全量值（只追加、不重排、不删除）
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'scope_type' AND n.nspname = 'platform'
    ) THEN
        CREATE TYPE platform.scope_type AS ENUM ('all', 'dept_and_child', 'self', 'custom');
    END IF;
END $$;

COMMENT ON TYPE platform.scope_type IS '角色数据范围: all=全部 / dept_and_child=本部门及以下 / self=仅本人 / custom=自定义部门（059 转原生 ENUM，042 CHECK 移除）';
