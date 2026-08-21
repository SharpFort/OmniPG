-- api_v1/platform/rpc/rpc_webhook_logto.sql
-- FUNCTION: api_v1_platform.webhook_logto（17 号文档归位：迁移 050_suspension_sync.sql 删定义段，本文件为唯一权威）
-- 回放终态: 050_suspension_sync.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
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
GRANT EXECUTE ON FUNCTION api_v1_platform.webhook_logto(jsonb) TO web_anon;
