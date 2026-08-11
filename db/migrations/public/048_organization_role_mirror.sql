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
DROP POLICY IF EXISTS org_role_select_policy ON organization_role;
CREATE POLICY org_role_select_policy ON organization_role
FOR SELECT
USING (true);

-- 展示视图（PostgREST 原生 GET /api_v1_public/organization_role）
DROP VIEW IF EXISTS api_v1_public.organization_role CASCADE;
CREATE VIEW api_v1_public.organization_role AS
SELECT id, name, description, created_at, updated_at
FROM organization_role;
COMMENT ON VIEW api_v1_public.organization_role IS '组织角色镜像视图（D4 展示接口；只读）';
GRANT SELECT ON api_v1_public.organization_role TO authenticated;

-- ---------------------------------------------------------------------------
-- §2 sync_organization_role_upsert / sync_organization_role_delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_organization_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO organization_role (id, name, description, created_at, updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        now(),
        COALESCE(logto_ts(data->>'updatedAt'), now())
    )
    ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        updated_at  = EXCLUDED.updated_at;
END $$;
COMMENT ON FUNCTION sync_organization_role_upsert(jsonb) IS '组织角色镜像 upsert（data: id/name/description；updatedAt 可选）';

CREATE OR REPLACE FUNCTION sync_organization_role_delete(p_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM organization_role WHERE id = p_id;
END $$;
COMMENT ON FUNCTION sync_organization_role_delete(text) IS '组织角色镜像删除（data=null，ID 取 params.id——N1 同款）';

-- ---------------------------------------------------------------------------
-- §3 webhook_logto 重写（046 版 + OrganizationRole.* 分支；N1/N6 语义保持）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_sys.webhook_logto(jsonb);
CREATE FUNCTION api_v1_sys.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_event  text := $1->>'event';
    v_data   jsonb := $1->'data';
    v_log_id uuid;
    v_failed boolean := false;
BEGIN
    -- N6: 事件落库（received；日志写入失败不阻断处理）
    BEGIN
        INSERT INTO webhook_event_log (hook_id, event, logto_created, payload)
        VALUES ($1->>'hookId', v_event, logto_ts($1->>'createdAt'), $1)
        RETURNING id INTO v_log_id;
    EXCEPTION WHEN OTHERS THEN
        v_log_id := NULL;
    END;

    CASE v_event
        -- ═══ 用户事件 ═══
        WHEN 'User.Created' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Data.Updated' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Deleted' THEN
            -- N1: data=null，删除 ID 在 params；三键兜底
            PERFORM sync_user_delete(
                COALESCE($1->'params'->>'userId', $1->'params'->>'id', v_data->>'id'));

        -- ═══ 组织（租户）事件 ═══
        WHEN 'Organization.Created' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Data.Updated' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Deleted' THEN
            -- N1: DELETE /organizations/:id → params.id
            PERFORM sync_tenant_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 成员关系事件（增量 diff）═══
        WHEN 'Organization.Membership.Updated' THEN
            PERFORM sync_membership_delta(
                $1->>'organizationId',
                COALESCE($1->'addedUserIds', '[]'::jsonb),
                COALESCE($1->'removedUserIds', '[]'::jsonb));

        -- ═══ 组织角色事件（D4）═══
        WHEN 'OrganizationRole.Created' THEN
            PERFORM sync_organization_role_upsert(v_data);
        WHEN 'OrganizationRole.Data.Updated' THEN
            PERFORM sync_organization_role_upsert(v_data);
        WHEN 'OrganizationRole.Deleted' THEN
            -- N1: DELETE /organization-roles/:id → params.id
            PERFORM sync_organization_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 角色目录事件 ═══
        WHEN 'Role.Created' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Data.Updated' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Deleted' THEN
            -- N1: DELETE /roles/:id → params.id
            PERFORM sync_role_delete(
                COALESCE($1->'params'->>'id', $1->'params'->>'userId', v_data->>'id'));

        -- ═══ 登录事件（D-C：interaction payload 顶层平铺，无 data 包装）═══
        WHEN 'PostSignIn' THEN
            -- N6: 登录日志独立容错——失败仅落 error 不阻断（避免重试双写）
            BEGIN
                PERFORM sync_login_log_write($1);
            EXCEPTION WHEN OTHERS THEN
                v_failed := true;
                IF v_log_id IS NOT NULL THEN
                    UPDATE webhook_event_log
                       SET result = 'error', error = SQLERRM
                     WHERE id = v_log_id;
                END IF;
            END;

        -- ═══ 未知事件 — 落 ignored（测试负载/未来新事件可观测）═══
        ELSE
            IF v_log_id IS NOT NULL THEN
                UPDATE webhook_event_log SET result = 'ignored' WHERE id = v_log_id;
            END IF;
    END CASE;

    -- N6: 成功落库（PostSignIn 失败/未知事件已单独标记，不覆盖）
    IF v_log_id IS NOT NULL AND NOT v_failed
       AND NOT EXISTS (SELECT 1 FROM webhook_event_log WHERE id = v_log_id AND result <> 'received') THEN
        UPDATE webhook_event_log SET result = 'success' WHERE id = v_log_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    -- N6: 失败落库（error）并返回 ok:false；参数 $1 不回滚，用于匹配 received 行
    BEGIN
        UPDATE webhook_event_log
           SET result = 'error', error = SQLERRM
         WHERE id = (SELECT id FROM webhook_event_log
                     WHERE payload = $1 AND result = 'received'
                     ORDER BY created_at DESC LIMIT 1);
        IF NOT FOUND THEN
            INSERT INTO webhook_event_log (hook_id, event, logto_created, payload, result, error)
            VALUES ($1->>'hookId', $1->>'event', logto_ts($1->>'createdAt'), $1, 'error', SQLERRM);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api_v1_sys.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；N6 事件落库；N1 删除 ID 三键兜底；D4 OrganizationRole.* 分支；PostSignIn 失败容忍';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_logto(jsonb) TO web_anon;

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
    RAISE NOTICE '048: 表=% 函数=% 视图=% 策略=%（期望 1/2/1/1）', v_tbl, v_fn, v_view, v_pol;
    IF v_tbl <> 1 OR v_fn <> 2 OR v_view <> 1 OR v_pol <> 1 THEN
        RAISE EXCEPTION '048 验证失败';
    END IF;
    RAISE NOTICE '048: 全部验证通过';
END $$;
