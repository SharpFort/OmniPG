-- =============================================================================
-- 048_organization_role_mirror.sql — D4 组织角色独立镜像（33 号文档 §9 D4）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板——独立 organization_role 表（不合并进 role）；
--   订阅 OrganizationRole.Created/Data.Updated/Deleted；新增展示接口。
-- 实体核实（官方 webhooks-request 页）: OrganizationRole = {id, name, description?}
--   —— 无 type/isDefault（与全局 Role 实体不同）；与全局角色独立命名空间
--   （role.name 唯一索引，合并会造成同名冲突）。
-- 订阅: init-logto.py step5 已补 OrganizationRole.* 三项（N3，2026-08-11）。
-- 注意: 用户↔组织角色分配无 webhook 事件（官方注册表核实）→ 成员展示走对账任务（D9）。
-- 幂等: IF NOT EXISTS / CREATE OR REPLACE / DROP+CREATE+GRANT 可重放。
-- 依赖: uuidv7（PG18 内置，无）、webhook_logto（046 版，本迁移重写追加分支）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 organization_role 镜像表（Logto 权威 → PG 只读投影）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS organization_role (
    id          text PRIMARY KEY,                       -- Logto organization role id（nanoid）
    name        varchar(128) NOT NULL,                  -- 组织角色名（F20 全局唯一）
    description text NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE organization_role IS 'Logto 组织角色镜像表（独立于 role 全局角色；只读投影，写入通道 = sync_organization_role_*）';
COMMENT ON COLUMN organization_role.id IS 'Logto organization role id（21 位 nanoid）';

CREATE UNIQUE INDEX IF NOT EXISTS idx_org_role_name ON organization_role(name);

GRANT SELECT ON organization_role TO authenticated;

ALTER TABLE organization_role ENABLE ROW LEVEL SECURITY;

-- 展示视图（PostgREST 原生 GET /api_v1_public/organization_role）


-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.organization_role') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.organization_role TO authenticated;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §2 sync_organization_role_upsert / sync_organization_role_delete
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §3 webhook_logto 重写（046 版 + OrganizationRole.* 分支；N1/N6 语义保持）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tbl int; v_fn int; v_view int; v_pol int;
BEGIN
    SELECT count(*) INTO v_tbl FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'organization_role';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('sync_organization_role_upsert', 'sync_organization_role_delete');
    SELECT count(*) INTO v_view FROM pg_views
    WHERE schemaname = 'api_v1_public' AND viewname = 'organization_role';
    SELECT count(*) INTO v_pol FROM pg_policies WHERE tablename = 'organization_role';
    RAISE NOTICE '048: 表=% 函数=% 视图=% 策略=%（dbmate 阶段函数/视图/策略=0，apply-src 后=2/1/1）', v_tbl, v_fn, v_view, v_pol;
    -- 环境自适应（17 号文档）：函数/视图/策略已迁 src，dbmate up 阶段不存在
    IF v_tbl <> 1 OR NOT (v_fn IN (0, 2)) OR NOT (v_view IN (0, 1)) OR NOT (v_pol IN (0, 1)) THEN
        RAISE EXCEPTION '048 验证失败';
    END IF;
    RAISE NOTICE '048: 全部验证通过';
END $$;
