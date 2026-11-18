-- db/src/platform/types/gender.sql
-- 语义: 用户性别（user_profile.gender；隐私友好四值，GDPR 惯例）
--       使用位置: user_profile.gender（060 建表引用，bootstrap 前置建）
-- 演进史: v1 四值（2026-08-14 060 决策：male/female/other/prefer_not_to_say）；
--         2026-08-15 用户拍板改名 iam_gender → gender（更简洁，与列名一致）
-- 废弃值: 无（值只增不删；废弃用 z_deprecated_* 前缀 RENAME VALUE，永不删除）
-- 排序语义: 无排序需求（展示值；前端按 locale 映射）

-- ① 当前态全量值（只追加、不重排、不删除）
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'gender' AND n.nspname = 'platform'
    ) THEN
        CREATE TYPE platform.gender AS ENUM ('male', 'female', 'other', 'prefer_not_to_say');
    END IF;
END $$;

COMMENT ON TYPE platform.gender IS '用户性别（user_profile.gender）: male=男 / female=女 / other=其他 / prefer_not_to_say=不愿透露（隐私友好，GDPR 惯例）';
