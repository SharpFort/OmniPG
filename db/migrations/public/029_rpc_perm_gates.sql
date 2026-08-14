-- =============================================================================
-- 029_rpc_perm_gates.sql — DEFINER 写/管理 RPC 补 has_permission 门槛
-- =============================================================================
-- 背景: 2026-08-05 用户拍板（05.4 权限校验三层模型 P-3）
--   旧 DEFINER 写/管理 RPC（绕过 RLS + 无门槛）= 任何 authenticated 可执行：
--     update_config / import_csv / export_csv / cleanup_expired_tokens
--   补齐权限点 + 入口门槛（与 024/025 新 CRUD 统一模式）
-- 权限点: sys:config:write / sys:import（⚠️ 035 删 sys:export——export_csv 已删除，
--   导出走 GET /view 原生能力；删 sys:session:cleanup——cleanup_expired_tokens
--   整链死链删除，会话/吊销交 Logto 无可清理之物）
--   绑定: role_super_admin（tenant_admin 不授予——配置/导入为平台级）
-- 幂等: CREATE OR REPLACE（函数）+ ON CONFLICT（seed）；apply-src 重放安全
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 权限点 seed + 超管绑定
-- ---------------------------------------------------------------------------
INSERT INTO iam_api (api_code, path, method, name, is_active)
SELECT x.api_code, '/rpc/' || x.api_code, 'POST', x.name, true
FROM (VALUES
    ('sys:config:write',     '配置-写入'),
    ('sys:import',           '数据-导入')
) AS x(api_code, name)
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id)
SELECT 'role_super_admin', id FROM iam_api
WHERE api_code IN ('sys:config:write','sys:import')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §1 update_config — 补 sys:config:write 门槛
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §2 import_csv — 补 sys:import 门槛
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §3 export_csv — ⚠️ 035 已删除（半成品：返回提示文本非数据；DEFINER + 裸 SQL 拼接
--    注入面；PostgREST 不支持流式 COPY。导出 = GET /api_v1_public/{view}?select=...
--    RLS 生效 + Range 分页，前端拼 CSV。源文件 rpc_export_csv.sql 已 git rm，
--    已执行环境由 035 DROP FUNCTION IF EXISTS 兜底）
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §4 cleanup_expired_tokens — ⚠️ 035 已整链删除（死链：public.cleanup_expired_tokens()
--     全库无定义（本 wrapper 内部 PERFORM 目标不存在）；清理对象
--     sys_token_blacklist/sys_user_session 014 已删（D12 会话/吊销交 Logto）；
--     无可清理之物，cron 任务 cleanup-expired-tokens 一并删除（034 重调度作废，
--     §2.2 审查发现）。源文件无（迁移内定义），已执行环境由 035 DROP 兜底）
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_gates int; v_perms int;
BEGIN
    -- 环境自适应（17 号文档：函数已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    SELECT count(*) INTO v_gates FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('update_config','import_csv')
        AND prosrc LIKE '%has_permission%';
    SELECT count(*) INTO v_perms FROM iam_api
      WHERE api_code IN ('sys:config:write','sys:import');
    RAISE NOTICE '029: 门槛函数=%（期望2） 权限点=%（期望2）', v_gates, v_perms;
END $$;
