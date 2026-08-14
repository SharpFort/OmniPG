-- =============================================================================
-- 013_casdoor_cleanup.sql — T7: Casdoor 资产清理（视图重建 + 表体退役）
-- =============================================================================
-- 背景: Casdoor 时代 IAM 表（sys_role/sys_user_role/sys_role_api/sys_role_menu/
--       sys_user_role_request）已由 Logto 镜像表（role/iam_role_api/
--       iam_role_menu/user_tenants）替代（009/011/012）。
--       api_v1_sys.* 视图是前端兼容层（PostgREST 出口），重建为 Logto 语义；
--       Casdoor 表体退役删除（数据已无业务引用，超管角色数据在 011 已重新种子）。
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 重建 api_v1_sys.sys_role → role 投影（Logto 全局角色目录）
--    列兼容旧视图（id/role_code/role_name/tenant_id/description/is_active/...）
--    先 DROP（旧视图列类型 uuid → 新 text，CREATE OR REPLACE 不允许改类型）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_role CASCADE;


-- ---------------------------------------------------------------------------
-- §2 重建 api_v1_sys.sys_user_role → user_tenants 投影（Logto 组织成员关系）
--    Logto 语义：用户-组织成员 = user_tenants；组织角色在 Logto organization_roles
--    （app_db 未镜像角色绑定，成员关系即授权面）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_user_role CASCADE;


-- ---------------------------------------------------------------------------
-- §3 重建 v_role_list → role 投影 + 关联计数
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §4 重建 v_role_api_detail → iam_role_api 投影
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_role_api_detail CASCADE;


-- ---------------------------------------------------------------------------
-- §5 重建 v_role_menu_detail → iam_role_menu 投影
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §6 退役 Casdoor 时代 IAM 表体（数据已由 011 重新种子至 role 系列）
--    视图已重建 → 无依赖；sys_tenant 退役声明见 012（表体保留兼容）
--    注: DROP CASCADE 会连带删除引用视图（sys_role_api/sys_role_menu/
--        sys_user_role_request/v_system_stats_realtime），§7 重建/退役处理
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.sys_role CASCADE;
DROP TABLE IF EXISTS public.sys_role_api CASCADE;
DROP TABLE IF EXISTS public.sys_role_menu CASCADE;
DROP TABLE IF EXISTS public.sys_user_role CASCADE;
DROP TABLE IF EXISTS public.sys_user_role_request CASCADE;

-- ---------------------------------------------------------------------------
-- §7 重建被 CASCADE 连带删除的视图
-- ---------------------------------------------------------------------------
-- 7.1 sys_role_api → iam_role_api 投影（role_id = role.id，兼容前端关联）
DROP VIEW IF EXISTS api_v1_sys.sys_role_api CASCADE;


-- 7.2 sys_role_menu → iam_role_menu 投影
DROP VIEW IF EXISTS api_v1_sys.sys_role_menu CASCADE;


-- 7.3 sys_user_role_request — Casdoor 时代角色申请审批流（RPC 已 .deprecated）
--     Logto 由管理端分配角色，无申请语义 → 视图退役，不重建

-- 7.4 v_system_stats_realtime — 去掉已删 sys_user_role_request 的 pending 计数



-- ---------------------------------------------------------------------------
-- §8 验证（环境自适应：视图定义已归位 src/api_v1（17 号文档），dbmate up
--     阶段不存在则跳过；apply-src 全量重放时 src 已建 → 正常断言）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_roles int; v_apis int; v_menus int; v_members int;
    v_view_ok boolean;
BEGIN
    v_view_ok := to_regclass('api_v1_sys.v_role_list') IS NOT NULL;
    IF v_view_ok THEN
        SELECT count(*) INTO v_roles FROM api_v1_sys.v_role_list;
        SELECT count(*) INTO v_apis  FROM api_v1_sys.v_role_api_detail;
        SELECT count(*) INTO v_menus FROM api_v1_sys.v_role_menu_detail;
        SELECT count(*) INTO v_members FROM api_v1_sys.sys_user_role;
    END IF;
    RAISE NOTICE '013: 视图存在=% v_role_list=% v_role_api_detail=% v_role_menu_detail=% sys_user_role(成员)=%',
        v_view_ok, v_roles, v_apis, v_menus, v_members;
END $$;
