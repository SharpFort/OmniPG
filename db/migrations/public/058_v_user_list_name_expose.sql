-- =============================================================================
-- 058_v_user_list_name_expose.sql — v_user_list 暴露 name 列（前端用户页关键词搜索依赖）
-- =============================================================================
-- 背景: 2026-08-13 用户报障（P0）:
--   前端用户页关键词搜索已使用 PostgREST 过滤 or=(username.ilike, email.ilike, name.ilike)，
--   而 v_user_list 视图未暴露 users.name → 带关键词搜索报 42703 列不存在
--   （不带关键词的正常列表不受影响）
-- 决策:
--   视图 SELECT 列表在 u.primary_phone AS phone 之后加 u.name（其余列不变）；
--   历史迁移不动（v_user_list 仅源文件定义，024/035 只引用不重建）
-- 数据说明: Logto 用户 name 大多为空（1.users.csv 可见）——姓名匹配命中取决于
--   Logto 侧是否维护 name 字段，属数据问题非技术问题
-- 幂等: CREATE OR REPLACE VIEW 幂等重放；GRANT 随视图保留（grant_all.sql 已授
--   SELECT TO authenticated，重放源文件时补授）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================



-- ---------------------------------------------------------------------------
-- 验证 DO 块（新增列存在 + 原有关键列未丢）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_name_col int;
    v_orig_col int;
    v_view_ok  boolean;
BEGIN
    -- 环境自适应（17 号文档）：v_user_list 定义已迁 src/api_v1，dbmate up 阶段不存在则跳过
    v_view_ok := to_regclass('api_v1_public.v_user_list') IS NOT NULL;
    IF v_view_ok THEN
    SELECT count(*) INTO v_name_col FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'v_user_list'
      AND column_name = 'name';
    IF v_name_col <> 1 THEN
        RAISE EXCEPTION '058: v_user_list.name 列缺失（%）', v_name_col;
    END IF;

    SELECT count(*) INTO v_orig_col FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'v_user_list'
      AND column_name IN ('id','username','email','phone','tenant_id','dept_id',
                          'tenant_name','dept_name','is_active','created_at',
                          'updated_at','deleted_at','organizations');
    IF v_orig_col <> 13 THEN
        RAISE EXCEPTION '058: v_user_list 原有列缺失（期望13 实际%）', v_orig_col;
    END IF;

    RAISE NOTICE '058: v_user_list +name 列验证通过（新增列=1 原有列=13）';
    ELSE
        RAISE NOTICE '058: v_user_list 视图 dbmate 阶段不存在（src 提供），跳过列断言';
    END IF;
END $$;

-- PostgREST 模式缓存刷新（DDL 后必须，否则旧计划继续服务；044-046 惯例）
NOTIFY pgrst, 'reload schema';
