-- =============================================================================
-- 059_scope_type_native_enum.sql — scope_type TEXT+CHECK → 原生 ENUM（P0-8）
-- =============================================================================
-- 背景: 17 号文档 §8.2 政策（2026-08-14 用户拍板）——开发期一律原生 ENUM；
--       042 的 iam_role_data_scope.scope_type 是 TEXT+CHECK 形态（存量清零项）。
-- 方案（§8.6 转换流程，新编号迁移）:
--   ① 数据清理段前置（CHECK 会校验存量行——本列无历史违例，仍按规程前置）
--   ② ALTER COLUMN TYPE text → public.scope_type（USING cast，四值全合法）
--   ③ DROP CONSTRAINT iam_role_data_scope_type_check（值域由 ENUM 类型保证；
--      dept_consistency CHECK 保留——它约束的是 dept_id 与 scope_type 的联动）
--   ④ 类型本体由 db/src/public/types/scope_type.sql 提供（bootstrap 前置建，
--      幂等 DO 块；本节不 CREATE TYPE）
-- 联动（同提交，§8.6-4）:
--   - src 新增 db/src/public/types/scope_type.sql
--   - 042 的 current_data_scope/current_visible_dept_ids/rpc_get/set_role_data_scope
--     已随归位迁 src（042 删段）；函数体 scope_type 均以 text 字面量比较，
--     ENUM 列与 text 字面量比较自动隐式 cast（enum = 'all' 合法）→ 函数体无需改
-- 幂等: ALTER TYPE ... USING col::type 在列已是 enum 时重复执行安全；
--       DROP CONSTRAINT IF EXISTS 幂等。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 数据清理段（前置：CHECK 建约束会校验存量行；本列无违例，幂等兜底）
-- ---------------------------------------------------------------------------
UPDATE iam_role_data_scope
SET scope_type = 'self'::public.scope_type
WHERE scope_type::text NOT IN ('all', 'dept_and_child', 'self', 'custom');

-- ---------------------------------------------------------------------------
-- §2 列类型转换（text → enum）
--     042 的两个 CHECK 均含 text 字面量比较（IN/=/<>），列转 enum 后 operator
--     不存在 → 转换前全部 DROP；type_check 值域改由 ENUM 保证（不再重建），
--     dept_consistency 联动约束以 ::scope_type cast 版重建
-- ---------------------------------------------------------------------------
ALTER TABLE iam_role_data_scope
    DROP CONSTRAINT IF EXISTS iam_role_data_scope_type_check;
ALTER TABLE iam_role_data_scope
    DROP CONSTRAINT IF EXISTS iam_role_data_scope_dept_consistency;

ALTER TABLE iam_role_data_scope
    ALTER COLUMN scope_type DROP DEFAULT;  -- 先移除 text 默认值（enum 不能自动 cast DEFAULT）
ALTER TABLE iam_role_data_scope
    ALTER COLUMN scope_type TYPE public.scope_type
    USING scope_type::public.scope_type;
ALTER TABLE iam_role_data_scope
    ALTER COLUMN scope_type SET DEFAULT 'self'::public.scope_type;

-- 重建 dept_consistency（cast 版：enum 列与枚举字面量比较）
ALTER TABLE iam_role_data_scope
    ADD CONSTRAINT iam_role_data_scope_dept_consistency
    CHECK ((scope_type = 'custom'::public.scope_type AND dept_id IS NOT NULL)
        OR (scope_type <> 'custom'::public.scope_type AND dept_id IS NULL));

-- ---------------------------------------------------------------------------
-- §3 验证（结构 + 写入冒烟）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_type        text;
    v_check_left  int;
    v_all_ok      boolean;
BEGIN
    -- 列类型已为 enum
    SELECT t.typname INTO v_type
    FROM pg_type t JOIN pg_attribute a ON a.atttypid = t.oid
    WHERE a.attrelid = 'iam_role_data_scope'::regclass AND a.attname = 'scope_type';

    -- type_check 已移除、dept_consistency 保留
    SELECT count(*) INTO v_check_left FROM pg_constraint
    WHERE conname = 'iam_role_data_scope_dept_consistency';

    -- 四值写入冒烟（enum 强约束）
    BEGIN
        INSERT INTO iam_role_data_scope (role_code, scope_type) VALUES ('__scope_smoke__', 'all'::public.scope_type);
        DELETE FROM iam_role_data_scope WHERE role_code = '__scope_smoke__';
        v_all_ok := true;
    EXCEPTION WHEN OTHERS THEN
        v_all_ok := false;
    END;

    RAISE NOTICE '059: 列类型=%（期望 scope_type） dept_consistency=%（期望1） 四值写入=%（期望 true）',
        v_type, v_check_left, v_all_ok;

    IF v_type <> 'scope_type' OR v_check_left <> 1 OR NOT v_all_ok THEN
        RAISE EXCEPTION '059 验证失败';
    END IF;
    RAISE NOTICE '059: 全部验证通过';
END $$;
