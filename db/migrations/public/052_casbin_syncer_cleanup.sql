-- =============================================================================
-- 052_casbin_syncer_cleanup.sql — 移除 Policy Syncer 通知链（syncer 已删除）
-- =============================================================================
-- 背景（2026-08-11 决策）:
--   Casbin 授权方案已弃用（Logto IdP + iam_* 镜像表 + RPC 权限码方案替代），
--   APISIX authz-casbin 插件不再启用，Policy Syncer（db/casbin-syncer Go 服务）
--   已从仓库删除。本迁移清理其唯一 DB 依赖:
--     · trg_reload_on_role_api  — iam_role_api 变更触发器
--     · notify_policy_reload()  — pg_notify('casbin_channel', ...) 发送函数
--   casbin_rule 视图（运行视图，009/031/035/044 重建）保留——仍作为
--   iam_role_api + iam_role_menu 的投影供查询使用。
-- 依赖: iam_role_api（004/047 建）；casbin_rule 视图（044 版）不动。

DROP TRIGGER IF EXISTS trg_reload_on_role_api ON public.iam_role_api;

DROP FUNCTION IF EXISTS public.notify_policy_reload();
