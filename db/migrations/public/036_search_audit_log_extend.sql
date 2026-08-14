-- =============================================================================
-- 036_search_audit_log_extend.sql — 审计日志搜索增强（时间范围/操作人/表名模糊）
-- =============================================================================
-- 背景: 2026-08-08 OmniAdmin 审计日志搜索重构（用户拍板；docs/搜索组件与分页跳转规范.md 配套）
--   审计日志页搜索"不合适"的根因：
--     ① 无时间范围筛选（审计检索最核心维度；v_audit_log_detail 有 created_at 未用）
--     ② p_query 只匹配 old_data/new_data 内容，搜不到操作人（username）
--     ③ p_table_name 精确匹配（=），输入 user 查不到 sys_user
--   方案（与 rpc_search_login_logs 时间约定同构，左闭右闭）:
--     p_query       → username ILIKE OR old_data::text ILIKE OR new_data::text ILIKE
--     p_table_name  → table_name ILIKE '%'||p_table_name||'%'（模糊）
--     p_operation   → 精确匹配（不变；值域 INSERT/UPDATE/DELETE/NULL=操作审计）
--     p_start_date  → created_at >= p_start_date（timestamptz）
--     p_end_date    → created_at <= p_end_date（前端日期范围补 23:59:59）
--   兼容性: 新参数全部 DEFAULT NULL，旧调用不受影响；签名 5 参 → 7 参，
--   旧 5 参重载必须 DROP（否则 PGRST203 候选函数歧义，见 027 教训）
-- =============================================================================

-- 旧 5 参重载删除（CREATE OR REPLACE 不同参数列表 = 新增重载，旧版残留 → PGRST203）






-- =============================================================================
-- 验证块: 新签名存在 / 旧重载已删 / 权限已授
-- =============================================================================
DO $$
DECLARE
    v_new   int;
    v_old   int;
    v_grant int;
BEGIN
    -- 环境自适应（17 号文档：函数已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    v_new := CASE WHEN to_regprocedure('api_v1_public.search_audit_log(text,text,text,timestamptz,timestamptz,int,int)') IS NOT NULL
                  THEN 1 ELSE 0 END;
    v_old := 0;
    SELECT count(*) INTO v_grant FROM information_schema.role_routine_grants
      WHERE routine_schema = 'api_v1_public'
        AND routine_name = 'search_audit_log'
        AND grantee = 'authenticated';
    RAISE NOTICE '036: 新签名=%（期望1） 旧重载=%（期望0） authenticated授权=%（期望1）',
        v_new, v_old, v_grant;
    -- 环境自适应（17 号文档）：函数已迁 src/api_v1，dbmate up 阶段不存在则跳过
    IF v_new = 1 AND (v_old <> 0 OR v_grant < 1) THEN
        RAISE EXCEPTION '036: 验证失败 new=% old=% grant=%', v_new, v_old, v_grant;
    END IF;
END $$;
