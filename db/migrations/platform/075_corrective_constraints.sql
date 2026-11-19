-- 075_corrective_constraints.sql
-- 075（2026-11-19）：静态审查修正迁移（OpenCodeReview 批次 2c · 依据 065/068/069 发现）
-- 内容：
--   1) 修复 D26 双列标识唯一索引的 NULLS DISTINCT 失效（065:353 / 068:168）：
--      role_id/org_role_id 恰一非空语义下，(r, NULL, m) 此前可无限重复插入，
--      rpc_set_role_menus 的 ON CONFLICT 永不触发——重建为 NULLS NOT DISTINCT
--   2) （验收修正后移除）恰一非空 CHECK 已由 068:150-165 以 VALID 形态存在
--      （iam_role_menu_role_ref_check / iam_role_data_scope_role_ref_check），不重复添加
--   3) 修正 069:165 的误导性约束改名（仅影响 pre-D26 升级库：约束实际指向
--      public.tenants 却被改名为 *_organization_id_fkey——按指向恢复原名）
--   4) 清理基线重复索引 idx_config_key（sys_config_config_key_key UNIQUE
--      约束的背书索引已覆盖同列，065:430）
--   5) 清理退役残留 api_v1_public.webhook_logto（067 删除 sync_* 后其函数体
--      PERFORM 悬空；该 schema 已于 b889343 从网关配置退役）
--   6) 种子 platform:menu:list 按钮权限码（rpc_get_menu_tree_admin 鉴权门的
--      目标收敛码，2a 批 TODO；管理员页现有 menu:update/create/delete 仍并行放行）
-- migrate:up

-- =============================================================================
-- 1. 去重（唯一索引重建前置）：仅删除完全重复键的冗余行，保留最早物理行
-- =============================================================================
DELETE FROM platform.iam_role_menu a
USING platform.iam_role_menu b
WHERE a.ctid > b.ctid
  AND a.role_id IS NOT DISTINCT FROM b.role_id
  AND a.org_role_id IS NOT DISTINCT FROM b.org_role_id
  AND a.menu_id = b.menu_id;

DROP INDEX IF EXISTS platform.iam_role_menu_role_menu_key;
CREATE UNIQUE INDEX iam_role_menu_role_menu_key
    ON platform.iam_role_menu (role_id, org_role_id, menu_id) NULLS NOT DISTINCT;

DELETE FROM platform.iam_role_data_scope a
USING platform.iam_role_data_scope b
WHERE a.ctid > b.ctid
  AND a.role_id IS NOT DISTINCT FROM b.role_id
  AND a.org_role_id IS NOT DISTINCT FROM b.org_role_id
  AND a.scope_type = b.scope_type
  AND a.dept_id IS NOT DISTINCT FROM b.dept_id;

DROP INDEX IF EXISTS platform.iam_role_data_scope_role_scope_key;
CREATE UNIQUE INDEX iam_role_data_scope_role_scope_key
    ON platform.iam_role_data_scope (role_id, org_role_id, scope_type, dept_id) NULLS NOT DISTINCT;

-- =============================================================================
-- 2.（已删除）恰一非空 CHECK：068:150-165 已存在等价且已 VALID 的
--    iam_role_menu_role_ref_check / iam_role_data_scope_role_ref_check，
--    本迁移不重复添加（批次2c 验收发现）
-- =============================================================================

-- =============================================================================
-- 3. 069:165 误导性改名修正（pre-D26 升级库；全新链为 no-op）
--    守卫按 (conrelid, conname) 限定：约束名仅在表内唯一（批次2c 验收修正）
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint c
               WHERE c.conname = 'user_profile_organization_id_fkey'
                 AND c.conrelid = 'platform.user_profile'::regclass
                 AND c.confrelid = 'public.tenants'::regclass)
       AND NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = 'user_profile_tenant_id_fkey'
                          AND conrelid = 'platform.user_profile'::regclass) THEN
        ALTER TABLE platform.user_profile
            RENAME CONSTRAINT user_profile_organization_id_fkey TO user_profile_tenant_id_fkey;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint c
               WHERE c.conname = 'user_position_organization_id_fkey'
                 AND c.conrelid = 'platform.user_position'::regclass
                 AND c.confrelid = 'public.tenants'::regclass)
       AND NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = 'user_position_tenant_id_fkey'
                          AND conrelid = 'platform.user_position'::regclass) THEN
        ALTER TABLE platform.user_position
            RENAME CONSTRAINT user_position_organization_id_fkey TO user_position_tenant_id_fkey;
    END IF;
END $$;

-- =============================================================================
-- 4. 基线重复索引清理
-- =============================================================================
DROP INDEX IF EXISTS platform.idx_config_key;

-- =============================================================================
-- 5. 退役残留清理（不可逆：该函数不再恢复）
-- =============================================================================
DROP FUNCTION IF EXISTS api_v1_public.webhook_logto(jsonb);

-- =============================================================================
-- 6. 种子：platform:menu:list 按钮权限码（挂靠菜单管理目录，同 create/update/delete）
--    端点按 PostgREST 路由 = 函数名去掉 rpc_ 前缀：/rpc/get_menu_tree_admin
--    （批次2c 验收修正）；先探 (api_url, api_method) 唯一索引防升级库撞 065:436
-- =============================================================================
INSERT INTO platform.iam_menu
    (id, parent_id, menu_name, router, icon, order_num, is_active,
     created_at, updated_at, created_by, updated_by,
     menu_type, api_code, component, is_visible, remark, route_name,
     is_link, is_iframe, redirect, is_cache, api_url, api_method, is_affix)
SELECT
    '019ffbf6-e0c1-7a9d-8f42-9c6d5f2b1e07', '019ffbf6-d6b7-7015-b0d5-ebb9b36ae970',
    '菜单-查询', NULL, NULL, 3, true,
    now(), now(), 'menu-rebuild-2026-08-14', NULL,
    'button', 'platform:menu:list', NULL, true, NULL, NULL,
    false, false, NULL, true, '/rpc/get_menu_tree_admin', 'POST', false
WHERE NOT EXISTS (SELECT 1 FROM platform.iam_menu
                  WHERE api_url = '/rpc/get_menu_tree_admin' AND api_method = 'POST')
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- 7. 父目录绑定回填（071:23 修正）：get_user_menu() 自根向下的递归 CTE 要求
--    每一层（含父目录）都存在 iam_role_menu 绑定；071 种子只绑定了叶子行，
--    绑定角色的菜单树会缺目录层。此处沿祖先闭包幂等补齐（NOT EXISTS 守卫，
--    tenant_id 沿用既有绑定行归属；目录行 api_code 为空，不影响 has_permission）
-- =============================================================================
WITH RECURSIVE bound AS (
    SELECT rm.role_id, rm.org_role_id, m.parent_id AS menu_id, rm.tenant_id
    FROM platform.iam_role_menu rm
    JOIN platform.iam_menu m ON m.id = rm.menu_id
    WHERE m.parent_id IS NOT NULL
),
ancestors AS (
    SELECT b.role_id, b.org_role_id, b.menu_id, b.tenant_id FROM bound b
    UNION
    SELECT a.role_id, a.org_role_id, m.parent_id, a.tenant_id
    FROM ancestors a
    JOIN platform.iam_menu m ON m.id = a.menu_id
    WHERE m.parent_id IS NOT NULL
)
INSERT INTO platform.iam_role_menu (role_id, org_role_id, menu_id, tenant_id, created_by)
SELECT DISTINCT ON (a.role_id, a.org_role_id, a.menu_id)
       a.role_id, a.org_role_id, a.menu_id, a.tenant_id, 'menu-backfill-075'
FROM ancestors a
WHERE NOT EXISTS (SELECT 1 FROM platform.iam_role_menu x
                  WHERE x.role_id IS NOT DISTINCT FROM a.role_id
                    AND x.org_role_id IS NOT DISTINCT FROM a.org_role_id
                    AND x.menu_id = a.menu_id)
  AND NOT (a.role_id IS NULL AND a.org_role_id IS NULL)
-- DISTINCT ON 按唯一键收敛（批次2c 验收修正）：ancestors 按 (role,org,menu,tenant)
-- 去重，同键多租户行会在单条 INSERT 内自相撞刚重建的 NULLS NOT DISTINCT 唯一索引
ORDER BY a.role_id, a.org_role_id, a.menu_id, a.tenant_id;

-- migrate:down

-- 反向恢复唯一索引为原 NULLS DISTINCT 形态（放弃恰一为空键的唯一性）
DROP INDEX IF EXISTS platform.iam_role_menu_role_menu_key;
CREATE UNIQUE INDEX iam_role_menu_role_menu_key
    ON platform.iam_role_menu (role_id, org_role_id, menu_id);

DROP INDEX IF EXISTS platform.iam_role_data_scope_role_scope_key;
CREATE UNIQUE INDEX iam_role_data_scope_role_scope_key
    ON platform.iam_role_data_scope (role_id, org_role_id, scope_type, dept_id);

CREATE INDEX IF NOT EXISTS idx_config_key ON platform.app_config USING btree (config_key);

DELETE FROM platform.iam_menu
WHERE id = '019ffbf6-e0c1-7a9d-8f42-9c6d5f2b1e07'
   OR (api_url = '/rpc/get_menu_tree_admin' AND api_method = 'POST' AND created_by = 'menu-rebuild-2026-08-14');
DELETE FROM platform.iam_role_menu WHERE created_by = 'menu-backfill-075';

-- 注：§3 约束改名与 §5 函数删除不恢复（恢复亦无意义：指向修正/退役对象）
