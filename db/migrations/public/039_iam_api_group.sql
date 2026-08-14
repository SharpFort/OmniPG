-- =============================================================================
-- 039_iam_api_group.sql — iam_api 分组归属（P0，2026-08-09 用户拍板）
-- =============================================================================
-- 背景: 菜单/API 管理优化结论落地（建议 3；用户认可"一键授权菜单全子树 API"交互）
--   iam_api 41 个权限点平铺无分组 → 角色授权界面无法按菜单树逐级勾选，
--   "给菜单即给其下接口"的授权直觉无法表达（BladeX blade_scope_api.menu_id /
--   Keycloak Resource 分组同款设计）
-- 决策:
--   D1 iam_api.menu_id → iam_menu(id)（ON DELETE SET NULL；权限点归属菜单）
--   D2 iam_api.api_group 冗余展示分组（回填=归属菜单名，管理端列表直接展示；
--       冗余列换取零 join 展示——BladeX scope_name 同思路）
--   D3 历史死端点（/sys_api /sys_menu /sys_role /sys_user——015/018 清理后
--       PostgREST 已无这些端点）保留不删（55 条 role_api 绑定中可能引用），
--       归组为对应菜单/API管理，提示用户在管理端复核
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_api 视图（+menu_id/api_group）
--   - api_v1_public.v_role_api_detail（+api_group/menu_id）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同步）:
--   - db/api_v1/public/views/iam_api.sql
--   - db/api_v1/public/views/v_role_api_detail.sql
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_api 加列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_api
    ADD COLUMN IF NOT EXISTS menu_id   uuid REFERENCES public.iam_menu(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS api_group text;

COMMENT ON COLUMN public.iam_api.menu_id IS '归属菜单（权限点分组锚点；一键授权菜单子树 API 的 join key；ON DELETE SET NULL）';
COMMENT ON COLUMN public.iam_api.api_group IS '展示分组名（回填=归属菜单名；冗余列，零 join 展示）';

CREATE INDEX IF NOT EXISTS idx_iam_api_menu ON public.iam_api(menu_id);

-- ---------------------------------------------------------------------------
-- §2 回填（幂等：仅补 NULL；按 path 模式映射到现有菜单树）
--    41 = 菜单7 + API4 + 角色6 + 用户4 + 部门3 + 字典3 + 岗位5 + 配置1
--        + 资料1 + 日志1 + 导入1 + 租户2 + 基础3
-- ---------------------------------------------------------------------------
UPDATE iam_api a SET menu_id = m.id, api_group = '菜单管理'
FROM iam_menu m
WHERE m.menu_name = 'MenuList'
  AND a.menu_id IS NULL
  AND (a.path LIKE '/rpc/sys:menu:%' OR a.path = '/sys_menu');

UPDATE iam_api a SET menu_id = m.id, api_group = 'API管理'
FROM iam_menu m
WHERE m.menu_name = 'ApiList'
  AND a.menu_id IS NULL
  AND a.path = '/sys_api';

UPDATE iam_api a SET menu_id = m.id, api_group = '角色管理'
FROM iam_menu m
WHERE m.menu_name = 'RoleList'
  AND a.menu_id IS NULL
  AND (a.path LIKE '/rpc/sys:role%' OR a.path = '/sys_role');

UPDATE iam_api a SET menu_id = m.id, api_group = '用户管理'
FROM iam_menu m
WHERE m.menu_name = 'UserList'
  AND a.menu_id IS NULL
  AND a.path = '/sys_user';

-- 无菜单的权限点统一挂 System 根，按业务分组
UPDATE iam_api a SET menu_id = m.id, api_group = '部门管理'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path LIKE '/rpc/sys:dept:%';

UPDATE iam_api a SET menu_id = m.id, api_group = '字典管理'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path LIKE '/rpc/sys:dict:%';

UPDATE iam_api a SET menu_id = m.id, api_group = '岗位管理'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path LIKE '/rpc/sys:position:%';

UPDATE iam_api a SET menu_id = m.id, api_group = '系统配置'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path = '/rpc/sys:config:write';

UPDATE iam_api a SET menu_id = m.id, api_group = '用户资料'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path = '/rpc/sys:profile:update';

UPDATE iam_api a SET menu_id = m.id, api_group = '日志监控'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path = '/rpc/sys:login-log:list';

UPDATE iam_api a SET menu_id = m.id, api_group = '数据导入'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path = '/rpc/sys:import';

UPDATE iam_api a SET menu_id = m.id, api_group = '租户管理'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND a.path LIKE '/rpc/sys:tenant%';

UPDATE iam_api a SET menu_id = m.id, api_group = '系统基础'
FROM iam_menu m
WHERE m.menu_name = 'System'
  AND a.menu_id IS NULL
  AND (a.path = '/rpc/get_user_menu' OR a.path = '/rpc/approve_role_request' OR a.path = '/rpc/kick_user');

-- ---------------------------------------------------------------------------
-- §3 重建暴露视图（+menu_id/api_group；与 views/iam_api.sql 逐字一致）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_api CASCADE;

-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.iam_api') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.iam_api TO authenticated;
        GRANT ALL ON api_v1_public.iam_api TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §4 重建 v_role_api_detail（+api_group/menu_id；与 views/v_role_api_detail.sql 一致）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.v_role_api_detail CASCADE;

-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.v_role_api_detail') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.v_role_api_detail TO authenticated;
        GRANT ALL ON api_v1_public.v_role_api_detail TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols   int;
    v_ungrouped int;
    v_total  int;
    v_groups int;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_api'
      AND column_name IN ('menu_id','api_group');

    SELECT count(*), count(*) FILTER (WHERE menu_id IS NULL OR api_group IS NULL)
      INTO v_total, v_ungrouped FROM iam_api;

    SELECT count(DISTINCT api_group) INTO v_groups FROM iam_api WHERE api_group IS NOT NULL;

    RAISE NOTICE '039: 新列=%（期望2） 总数=% 未分组=%（期望0） 分组数=%（期望13）',
        v_cols, v_total, v_ungrouped, v_groups;

    IF v_cols <> 2 OR v_ungrouped <> 0 OR v_total <> 41 OR v_groups <> 13 THEN
        RAISE EXCEPTION '039 验证失败';
    END IF;
    RAISE NOTICE '039: 全部验证通过';
END $$;
