-- =============================================================================
-- 031_menu_type_enum.sql — menu_type PG ENUM 化（05.1 D-B 实例：少变复用枚举）
-- =============================================================================
-- 背景: 2026-08-05 用户决策（前端联调期间）
--   menu_type 值集合极小（directory/menu/button）且几乎不变 → PG ENUM 适用场景
--   当前为 text 无表级约束（仅 024 RPC 内校验）→ ENUM 补表级强约束
-- 联动:
--   - 024 rpc_create_menu / rpc_update_menu：text 参数 → 显式 ::iam_menu_type
--     （text→enum 无隐式 cast，不重建会类型报错；函数内 IN 校验保留=前端友好报错）
--   - 011 种子默认 'menu'（历史）→ 031 转换后 DEFAULT 保留
-- 幂等: DO 块条件建类型 + ALTER TYPE 重复执行安全（enum→enum cast 自身）
-- 限制说明: PG ENUM 不能删值（本场景删除概率≈0）；PG18 支持事务内 ADD VALUE
-- 17 号文档归位登记（2026-08-14，§6.2 情形 a，P0-6）:
--   · iam_menu_type 定义迁 db/src/public/types/menu_type.sql（四值权威，bootstrap 前置）
--   · §0 类型创建段已删（bootstrap 建）；§1 视图重建段已删（src 视图权威，
--     ALTER TYPE 加 CASCADE 自动重建依赖视图——§9 迁移结构清理允许）
--   · §2 rpc_create_menu/rpc_update_menu 8 参版已删（终态 057 18 参版在
--     db/api_v1/public/rpc/rpc_create_menu.sql / rpc_update_menu.sql）
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 列转换（幂等：text → enum；CASCADE 重建依赖视图为 src 权威版）
-- ---------------------------------------------------------------------------
ALTER TABLE iam_menu ALTER COLUMN menu_type DROP DEFAULT;
ALTER TABLE iam_menu ALTER COLUMN menu_type TYPE iam_menu_type
    USING menu_type::iam_menu_type
    CASCADE;
ALTER TABLE iam_menu ALTER COLUMN menu_type SET DEFAULT 'menu'::iam_menu_type;

-- ---------------------------------------------------------------------------
-- §3 验证（列类型 + 默认值 + 非法值拒绝；函数联动检查已随 §2 归位移除）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_type     text;
    v_default  text;
    v_invalid  boolean;
BEGIN
    SELECT t.typname INTO v_type
    FROM pg_type t JOIN pg_attribute a ON a.atttypid = t.oid
    WHERE a.attrelid = 'iam_menu'::regclass AND a.attname = 'menu_type';
    SELECT pg_get_expr(d.adbin, d.adrelid)::text INTO v_default
    FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid = 'iam_menu'::regclass AND a.attname = 'menu_type';

    -- 非法值表级拒绝验证（enum 强约束）
    BEGIN
        INSERT INTO iam_menu (menu_name, menu_type) VALUES ('__test_invalid__', 'bad_type');
        v_invalid := false;  -- 不应到达
        DELETE FROM iam_menu WHERE menu_name = '__test_invalid__';
    EXCEPTION WHEN invalid_text_representation THEN
        v_invalid := true;
    END;

    RAISE NOTICE '031: 列类型=%（期望 iam_menu_type） 默认=%（期望 iam_menu_type） 非法值拒绝=%（期望 true）',
        v_type, v_default, v_invalid;

    IF v_type <> 'iam_menu_type' OR NOT v_invalid THEN
        RAISE EXCEPTION '031 验证失败';
    END IF;
    RAISE NOTICE '031: 全部验证通过';
END $$;
