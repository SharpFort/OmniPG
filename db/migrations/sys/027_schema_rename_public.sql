-- =============================================================================
-- 027_schema_rename_public.sql — api_v1_sys → api_v1_public（用户拍板）
-- =============================================================================
-- 背景: 2026-08-05 用户巡检："还需要将 api_v1_sys 重命名为 api_v1_public，
--       这也是可以直接替换的对吧？"
-- 方案（顺序无关、重放安全）:
--   - db/init/02-schemas.sql 已建 api_v1_sys（历史迁移引用承载）+ api_v1_public
--   - 本迁移（migrations 层，最后执行）:
--     ① api_v1_sys 存在 且 api_v1_public 不存在 → ALTER SCHEMA RENAME（首次迁移）
--     ② 双 schema 并存（重放场景：api_v1/public 目录文件已建权威副本）→
--        清理残留 api_v1_sys CASCADE（迁移层重复对象，无损失）
--     ③ api_v1_sys 不存在 → 跳过（已完成）
-- 最终态: 仅 api_v1_public，对象 = api_v1/public 目录文件（视图名=底层表名）+ 027 前各迁移
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api_v1_sys') THEN
        IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api_v1_public') THEN
            ALTER SCHEMA api_v1_sys RENAME TO api_v1_public;
            RAISE NOTICE '027: api_v1_sys → api_v1_public（RENAME 完成）';
        ELSE
            -- 重放场景：双 schema 并存。api_v1/public 目录文件（先于迁移执行）
            -- 已重建权威对象；迁移层在 api_v1_sys 的副本为残留 → 清理
            DROP SCHEMA api_v1_sys CASCADE;
            RAISE NOTICE '027: api_v1_public 已存在，清理残留 api_v1_sys（CASCADE）';
        END IF;
    ELSE
        RAISE NOTICE '027: api_v1_sys 不存在，跳过（已收敛）';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_sys int; v_public int; v_objs int;
BEGIN
    SELECT count(*) INTO v_sys FROM pg_namespace WHERE nspname = 'api_v1_sys';
    SELECT count(*) INTO v_public FROM pg_namespace WHERE nspname = 'api_v1_public';
    SELECT count(*) INTO v_objs FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'api_v1_public' AND c.relkind IN ('v','r');
    RAISE NOTICE '027: api_v1_sys=%（期望0） api_v1_public=%（期望1） 对象数=%', v_sys, v_public, v_objs;
END $$;
