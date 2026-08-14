-- ==============================================================================
-- Migration 011: iam_* 种子数据（API 目录 + 菜单树 + 初始角色绑定）
-- ------------------------------------------------------------------------------
-- 来源: 现有 sys_api/sys_menu 数据迁移（API/菜单目录属业务自主数据，非 Casdoor 资产，D26）
--      初始角色绑定按 D26 新模型：role_super_admin 拥有一切；租户角色暂留空
-- 幂等: ON CONFLICT DO NOTHING；重复执行不产生重复行
-- 引用: 06-开发路线 §3 T4、05-方案 §6.3（③ PG 自主表）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- §1 iam_api — 从 sys_api 迁移 API 权限点目录
--    排除旧 Casdoor 登录/刷新路由（已 deprecated）
-- ==============================================================================
DO $$ BEGIN
IF to_regclass('public.sys_api') IS NOT NULL THEN
INSERT INTO iam_api (path, method, name, description, is_active)
SELECT
    a.path,
    a.method,
    a.api_name,
    NULL::varchar AS description,   -- sys_api 视图无 description 列（api_v1_sys.sys_api 列集）
    (a.deleted_at IS NULL) AS is_active
FROM sys_api a
WHERE a.deleted_at IS NULL                                          -- 排除软删
  AND a.path NOT IN ('/rpc/user_login_sso', '/rpc/refresh_token_rtr') -- Casdoor 遗留
  AND a.path NOT IN ('/rpc/create_user')                           -- Casdoor Management API 创建用户
ON CONFLICT (path, method) DO UPDATE SET
    name        = EXCLUDED.name,
    description = EXCLUDED.description,
    is_active   = EXCLUDED.is_active,
    updated_at  = now();
END IF;
END $$;

DO $$ BEGIN RAISE NOTICE 'Seeded iam_api: % rows', (SELECT count(*) FROM iam_api); END $$;

-- ==============================================================================
-- §2 iam_menu — 从 sys_menu 迁移菜单树
--    假设 sys_menu 中存在数据；若空则跳过
-- ==============================================================================
DO $$ BEGIN
-- 幂等修正（2026-08-14）：044 已把 iam_menu.path 改名 router，重放时 path 列不存在则跳过
IF to_regclass('public.sys_menu') IS NOT NULL
   AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='iam_menu' AND column_name='path') THEN
INSERT INTO iam_menu (id, parent_id, menu_name, path, icon, order_num, is_active)
SELECT
    m.id,
    m.parent_id,
    m.name       AS menu_name,      -- sys_menu 视图列名: name（非 menu_name）
    m.path,
    m.icon,
    COALESCE(m.sort_order, 0),      -- sys_menu 视图列名: sort_order（非 order_num）
    (m.deleted_at IS NULL) AS is_active
FROM sys_menu m
WHERE m.deleted_at IS NULL
ON CONFLICT (id) DO UPDATE SET
    menu_name  = EXCLUDED.menu_name,
    path       = EXCLUDED.path,
    icon       = EXCLUDED.icon,
    order_num  = EXCLUDED.order_num,
    is_active  = EXCLUDED.is_active,
    updated_at = now();
END IF;
END $$;

DO $$ BEGIN RAISE NOTICE 'Seeded iam_menu: % rows', (SELECT count(*) FROM iam_menu); END $$;

-- ==============================================================================
-- §3 iam_role_api — 初始角色→API 绑定
--    role_super_admin（Logto 全局超管角色）= 拥有全部 API
--    租户角色（tenant_admin/editor/viewer）绑定由管理端按需添加（iam_role_api CRUD）
-- ==============================================================================

-- 超管 = 全部 API
INSERT INTO iam_role_api (role_code, api_id)
SELECT 'role_super_admin', a.id
FROM iam_api a
WHERE a.is_active = true
ON CONFLICT (role_code, api_id) DO NOTHING;

DO $$ BEGIN RAISE NOTICE 'Seeded iam_role_api (role_super_admin): % rows',
    (SELECT count(*) FROM iam_role_api WHERE role_code = 'role_super_admin'); END $$;

-- ==============================================================================
-- §4 iam_role_menu — 初始角色→菜单绑定
--    超管 = 全部菜单；其余角色由管理端按需添加
-- ==============================================================================
INSERT INTO iam_role_menu (role_code, menu_id)
SELECT 'role_super_admin', m.id
FROM iam_menu m
WHERE m.is_active = true
ON CONFLICT (role_code, menu_id) DO NOTHING;

DO $$ BEGIN RAISE NOTICE 'Seeded iam_role_menu (role_super_admin): % rows',
    (SELECT count(*) FROM iam_role_menu WHERE role_code = 'role_super_admin'); END $$;

-- ==============================================================================
-- §5 默认 tenant/users 登录种子（webhook 同步之前的手工兜底）
--    为 dev 环境预设标记行（不影响 Logto 端实际数据；webhook 首次同步自行覆盖）
--    id 为占位符（nanoid 格式），会在首次 webhook Organization.Created 后被 Logto 真实 id 覆盖
--    若 ON CONFLICT 触发 indicates tenant 已存在 → webhook 已运行 → 跳过
-- ==============================================================================
-- 此处不预设具体 tenant（由 Logto Console 创建 → webhook 自动同步）
-- 如需本地测试可直接 INSERT 占位租户

-- ==============================================================================
-- 注意: 本项目迁移由 apply-src.sh 幂等重放（psql 全文件执行，不识别
--       -- migrate:down 分段标记），故不设 down 段（避免种子被误删）。
--       回滚走整体 pg_dump restore。
-- ==============================================================================
