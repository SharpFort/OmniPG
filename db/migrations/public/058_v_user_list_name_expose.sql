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

CREATE OR REPLACE VIEW api_v1_public.v_user_list AS
SELECT
    u.id,
    u.username,
    u.primary_email AS email,
    u.primary_phone AS phone,
    u.name,                          -- ← 058 新增（前端关键词搜索姓名匹配）
    p.tenant_id,
    p.dept_id,
    t.name AS tenant_name,
    d.dept_name,
    (NOT u.is_suspended) AS is_active,
    u.created_at,
    u.updated_at,
    u.deleted_at,
    COALESCE(
        (SELECT json_agg(ut.organization_id ORDER BY ut.organization_id)
         FROM public.user_tenants ut
         WHERE ut.user_id = u.id),
        '[]'::json
    ) AS organizations
FROM public.users u
LEFT JOIN public.user_profile p ON p.user_id = u.id
LEFT JOIN public.tenants t ON p.tenant_id = t.id
LEFT JOIN public.department d ON p.dept_id = d.id;

COMMENT ON VIEW api_v1_public.v_user_list IS '用户列表视图（058 +name 列：前端关键词搜索姓名匹配；含租户名、部门名、组织成员关系）';

-- ---------------------------------------------------------------------------
-- 验证 DO 块（新增列存在 + 原有关键列未丢）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_name_col int;
    v_orig_col int;
BEGIN
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
END $$;

-- PostgREST 模式缓存刷新（DDL 后必须，否则旧计划继续服务；044-046 惯例）
NOTIFY pgrst, 'reload schema';
