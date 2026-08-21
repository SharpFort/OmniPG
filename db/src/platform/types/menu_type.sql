-- db/src/platform/types/menu_type.sql
-- 菜单类型枚举（少变复用枚举，05.1 D-B 实例：PG ENUM）
-- 当前态: 四值封闭（directory/menu/button/link）——2026-08-05 决策补 link（032）
-- 演进历史: 031_menu_type_enum 建三值 → 032_menu_type_link ADD VALUE 'link'
--   → 本文件声明当前态；apply-src 幂等重放（duplicate_object 跳过），
--   与迁移链两种应用顺序均收敛一致。
-- 引用: iam_menu.menu_type 列（031 ALTER COLUMN TYPE iam_menu_type）；
--   rpc_create_menu / rpc_update_menu 显式 cast + IN 校验（032/044/045）；
--   033 分类回填、046 link 语义（外链不挂接口）复用同一枚举。
-- 语义: link 类型 = path 为 http(s):// 外部链接或 iframe 内嵌 URL；component 留空

DO $$ BEGIN
    CREATE TYPE platform.iam_menu_type AS ENUM ('directory', 'menu', 'button', 'link');
EXCEPTION WHEN duplicate_object THEN null; END $$;

COMMENT ON TYPE platform.iam_menu_type IS '菜单类型（少变复用枚举）：directory=目录 / menu=菜单 / button=按钮 / link=外链或iframe（path 为 URL，component 留空）';
