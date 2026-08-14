-- =============================================================================
-- 018_final_cleanup.sql — T7: 残留函数收尾（ensure_user / get_role_permissions）
-- =============================================================================
-- ensure_user: 010 DB 版引用 sys_user_profile → user_profile（JIT 建档）
-- get_role_permissions: Casdoor 时代（sys_role/sys_role_api/sys_api）→ Logto
--   语义（role 镜像 + iam_role_api + iam_api）
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
--
-- 17 号文档归位登记（2026-08-14 仲裁，§6.2）:
--   · api_v1_sys.ensure_user()            —— 情形 a：迁移删定义，src 定稿
--     （终态 = 049 api_v1_public.ensure_user，源文件 db/api_v1/public/rpc/rpc_ensure_user.sql）
--   · api_v1_sys.get_role_permissions(text) —— 情形 a：迁移删定义，src 定稿
--     （终态 = 055 api_v1_public.get_role_permissions，源文件 db/api_v1/public/rpc/rpc_get_role_permissions.sql）
--   · 随迁 GRANT（api_v1_sys.* 版）已删——027 后 schema 不存在，src 文件自带
--     api_v1_public 版 GRANT EXECUTE（§1 约束 3 GRANT 归 grant_all.sql / src 文件）
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §3 验证：无残留引用旧表名函数
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_cnt int;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','api_v1_sys')
      AND p.prosrc ~ 'sys_(api|menu|tenant|secret|token_blacklist|user_session|user_legacy|role|user_role|user_profile|department|config|audit_log|cron_log)';
    RAISE NOTICE '018: 残留引用旧表名函数=%（预期 0）', v_cnt;
END $$;
