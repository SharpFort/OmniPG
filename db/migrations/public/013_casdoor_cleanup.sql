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
CREATE VIEW api_v1_sys.sys_role AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text                          AS tenant_id,      -- Logto 角色为全局（组织角色在 organization_roles）
    NULL::text                          AS description,
    NOT r.is_default                    AS is_active,      -- 默认角色视为内置（活跃）
    r.created_at,
    r.updated_at,
    NULL::timestamptz                   AS deleted_at,
    NULL::text                          AS created_by,
    NULL::text                          AS updated_by,
    NULL::text                          AS deleted_by
FROM role r;
COMMENT ON VIEW api_v1_sys.sys_role IS '角色表视图（Logto 镜像：role 投影，全局角色）';

-- ---------------------------------------------------------------------------
-- §2 重建 api_v1_sys.sys_user_role → user_tenants 投影（Logto 组织成员关系）
--    Logto 语义：用户-组织成员 = user_tenants；组织角色在 Logto organization_roles
--    （app_db 未镜像角色绑定，成员关系即授权面）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.sys_user_role CASCADE;
CREATE VIEW api_v1_sys.sys_user_role AS
SELECT
    ut.user_id,
    ut.organization_id AS role_id,      -- 兼容列名：组织即"角色域"
    ut.organization_id AS tenant_id,
    ut.joined_at AS created_at,
    NULL::text AS created_by
FROM user_tenants ut;
COMMENT ON VIEW api_v1_sys.sys_user_role IS '用户-角色关联视图（Logto 镜像：user_tenants 成员关系投影）';

-- ---------------------------------------------------------------------------
-- §3 重建 v_role_list → role 投影 + 关联计数
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_role_list CASCADE;
CREATE VIEW api_v1_sys.v_role_list AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    NOT r.is_default AS is_active,
    r.created_at,
    r.updated_at,
    NULL::timestamptz AS deleted_at,
    '全局'::character varying AS tenant_name,
    (SELECT count(*) FROM iam_role_api ra WHERE ra.role_code = r.role_code) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_code = r.role_code) AS menu_count,
    0::bigint AS users_count            -- Logto 全局角色无直接 user 绑定镜像；成员关系见 sys_user_role
FROM role r;
COMMENT ON VIEW api_v1_sys.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数）';

-- ---------------------------------------------------------------------------
-- §4 重建 v_role_api_detail → iam_role_api 投影
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_role_api_detail CASCADE;
CREATE VIEW api_v1_sys.v_role_api_detail AS
SELECT
    ra.id AS role_id,
    ra.api_id,
    ra.created_at,
    ra.role_code,
    COALESCE(r.name, ra.role_code) AS role_name,
    a.path,
    a.method,
    a.api_name,
    a.is_active AS api_is_active
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code
JOIN sys_api a ON a.id = ra.api_id;
COMMENT ON VIEW api_v1_sys.v_role_api_detail IS '角色-API 明细视图（Logto 镜像：iam_role_api）';

-- ---------------------------------------------------------------------------
-- §5 重建 v_role_menu_detail → iam_role_menu 投影
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_role_menu_detail CASCADE;
CREATE VIEW api_v1_sys.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.name AS menu_name,
    m.type AS menu_type,
    m.title AS menu_title,
    m.permission_code,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN sys_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_sys.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu）';

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
CREATE VIEW api_v1_sys.sys_role_api AS
SELECT r.id AS role_id, ra.api_id, ra.created_at, ra.created_by
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code;
COMMENT ON VIEW api_v1_sys.sys_role_api IS '角色-API 关联视图（Logto 镜像：iam_role_api）';

-- 7.2 sys_role_menu → iam_role_menu 投影
DROP VIEW IF EXISTS api_v1_sys.sys_role_menu CASCADE;
CREATE VIEW api_v1_sys.sys_role_menu AS
SELECT r.id AS role_id, rm.menu_id, rm.created_at, rm.created_by
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code;
COMMENT ON VIEW api_v1_sys.sys_role_menu IS '角色-菜单关联视图（Logto 镜像：iam_role_menu）';

-- 7.3 sys_user_role_request — Casdoor 时代角色申请审批流（RPC 已 .deprecated）
--     Logto 由管理端分配角色，无申请语义 → 视图退役，不重建

-- 7.4 v_system_stats_realtime — 去掉已删 sys_user_role_request 的 pending 计数
DROP VIEW IF EXISTS api_v1_sys.v_system_stats_realtime CASCADE;
CREATE VIEW api_v1_sys.v_system_stats_realtime AS
SELECT
    (SELECT COUNT(*) FROM public.sys_user_session WHERE is_used = FALSE AND expired_at > now()) AS online_users,
    (SELECT COUNT(*) FROM public.sys_token_blacklist WHERE expired_at > now()) AS blacklisted_tokens,
    (SELECT MAX(execution_time) FROM public.sys_cron_log WHERE job_name = 'cleanup-expired-tokens') AS last_cleanup_time,
    (SELECT COUNT(*) FROM public.sys_audit_log WHERE created_at > now() - interval '24 hours') AS audit_24h,
    now() AS stats_time;
COMMENT ON VIEW api_v1_sys.v_system_stats_realtime IS '实时系统统计视图（T7: 移除角色申请计数）';

-- ---------------------------------------------------------------------------
-- §8 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_roles int; v_apis int; v_menus int; v_members int;
BEGIN
    SELECT count(*) INTO v_roles FROM api_v1_sys.v_role_list;
    SELECT count(*) INTO v_apis  FROM api_v1_sys.v_role_api_detail;
    SELECT count(*) INTO v_menus FROM api_v1_sys.v_role_menu_detail;
    SELECT count(*) INTO v_members FROM api_v1_sys.sys_user_role;
    RAISE NOTICE '013: v_role_list=% v_role_api_detail=% v_role_menu_detail=% sys_user_role(成员)=%',
        v_roles, v_apis, v_menus, v_members;
END $$;
