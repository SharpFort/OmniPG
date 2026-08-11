-- =============================================================================
-- 050_suspension_sync.sql — D7 封禁状态同步（33 号文档 §9 D7）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板——封禁操作在 Logto 侧完成（OmniPG 不实现、不依赖）；
--   镜像仅同步 is_suspended 供展示；实时生效依赖 Logto 会话撤销 + 短 token。
-- 官方核实（webhooks-events 页触发表）: PATCH /users/:id/is-suspended
--   → User.SuspensionStatus.Updated（独立事件，User.Data.Updated 不触发）；
--   payload data = UserEntity（含 isSuspended 布尔）。
-- 实现: sync_user_suspension 幂等仅改 is_suspended；webhook_logto 追加分支
--   （048 版 + 新分支，N1/N6/D4 语义保持）。
-- 幂等: CREATE OR REPLACE / DROP+CREATE+GRANT 可重放。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 sync_user_suspension — 幂等仅改封禁列（不触碰其他权威字段）
--     用户行不存在则跳过（行由 User.Created / 对账建立；0 行更新无害）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_suspension(p_user_id text, p_suspended boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE users
       SET is_suspended = COALESCE(p_suspended, false),
           updated_at   = now()
     WHERE id = p_user_id;
END $$;
COMMENT ON FUNCTION sync_user_suspension(text, boolean) IS '封禁状态镜像同步（User.SuspensionStatus.Updated；幂等仅改 is_suspended；0 行更新无害）';

-- ---------------------------------------------------------------------------
-- §2 webhook_logto 重写（048 版 + User.SuspensionStatus.Updated 分支）
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
        WHEN 'User.SuspensionStatus.Updated' THEN
            -- D7: 封禁/解封（PATCH /users/:id/is-suspended 独立事件；data 含 isSuspended）
            PERFORM sync_user_suspension(
                v_data->>'id',
                COALESCE((v_data->>'isSuspended')::boolean, false));

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

COMMENT ON FUNCTION api_v1_sys.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；N6 事件落库；N1 删除 ID 三键兜底；D4 OrganizationRole.*；D7 SuspensionStatus.Updated；PostSignIn 失败容忍';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_logto(jsonb) TO web_anon;

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_fn int; v_src int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc WHERE proname = 'sync_user_suspension';
    SELECT count(*) INTO v_src FROM pg_proc
    WHERE proname = 'webhook_logto'
      AND pg_get_functiondef(oid) LIKE '%User.SuspensionStatus.Updated%';
    RAISE NOTICE '050: sync_user_suspension=% 分支=%（期望 1/1）', v_fn, v_src;
    IF v_fn <> 1 OR v_src <> 1 THEN
        RAISE EXCEPTION '050 验证失败';
    END IF;
    RAISE NOTICE '050: 全部验证通过';
END $$;
