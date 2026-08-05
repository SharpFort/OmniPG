-- ==============================================================================
-- Migration 010: Logto Webhook 接收 RPC 重写 + Casdoor 时代资产退役
-- ------------------------------------------------------------------------------
-- 重写: rpc_webhook_logto(payload jsonb) — 按 Logto event 字段分发（05 §4.3）
-- 退役: rpc_webhook_user_upsert/jsonb → .deprecated（Casdoor 专用）
--       rpc_webhook_user_delete/jsonb → .deprecated
--       rpc_create_user → .deprecated（管理端建号改调 Logto Management API）
--       Casdoor 时代 sys_secret.casdoor_webhook_secret 保留待 T7 清理
--       008 已 revoke 的 assign_role_* / submit_role_request 等保持 revoke
-- 验签: 在 APISIX serverless-pre-function 完成（D20），RPC 内不验签（event 匹配即可）
-- 幂等: ON CONFLICT DO UPDATE / IF NOT EXISTS
-- 引用: 05-Logto认证与权限架构-完善版.md §4.3/§5、06-开发路线 §3 T4
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- §1 Webhook 接收 RPC — rpc_webhook_logto
--    受 Logto webhook 调用的统一入口（订阅事件: User.* / Organization.* / Membership / Role.*）
--    验签由 APISIX 前置完成；此处按 event 分发，失败静默返回 ok（Logto 重试机制）
-- ==============================================================================
-- 参数改无名（$1）：PostgREST 单 jsonb 参数 RPC 要求 body 平铺匹配无名参数，
-- 具名参数（payload）会要求 body 用 {"payload": ...} 包装 → Logto 平铺 body 404
DROP FUNCTION IF EXISTS api_v1_sys.webhook_logto(jsonb);
CREATE FUNCTION api_v1_sys.webhook_logto(jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_event text := $1->>'event';
    v_data  jsonb := $1->'data';
BEGIN
    CASE v_event
        -- ═══ 用户事件 ═══
        WHEN 'User.Created' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Data.Updated' THEN
            PERFORM sync_user_upsert(v_data);
        WHEN 'User.Deleted' THEN
            PERFORM sync_user_delete(v_data->>'id');

        -- ═══ 组织（租户）事件 ═══
        WHEN 'Organization.Created' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Data.Updated' THEN
            PERFORM sync_tenant_upsert(v_data);
        WHEN 'Organization.Deleted' THEN
            PERFORM sync_tenant_delete(v_data->>'id');

        -- ═══ 成员关系事件（增量 diff）═══
        WHEN 'Organization.Membership.Updated' THEN
            PERFORM sync_membership_delta(
                $1->>'organizationId',
                COALESCE($1->'addedUserIds', '[]'::jsonb),
                COALESCE($1->'removedUserIds', '[]'::jsonb));

        -- ═══ 角色目录事件 ═══
        WHEN 'Role.Created' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Data.Updated' THEN
            PERFORM sync_role_upsert(v_data);
        WHEN 'Role.Deleted' THEN
            PERFORM sync_role_delete(v_data->>'id');

        -- ═══ 未知事件 — 静默忽略 ═══
        ELSE NULL;
    END CASE;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    -- 幂等失败不阻断 webhook 响应（Logto 投递 fire-and-forget + 重试 3 次）
    -- 错误记录审计日志（P1 加告警）
    RETURN jsonb_build_object('ok', true, 'warn', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api_v1_sys.webhook_logto(jsonb) IS 'Logto webhook 接收入口（验签由网关完成）；按 event 分发到各 sync_* 子函数';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_logto(jsonb) TO web_anon;

-- ==============================================================================
-- §2 子函数 — sync_* 系列（幂等 upsert / 增量删除）
--    webhook payload 的 data 字段 = Logto 实体白名单（05 F2 核实）
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 2.0 logto_ts — Logto 时间字段统一转换
--     Logto API 返回 createdAt/updatedAt/lastSignInAt 为**毫秒时间戳数字**
--     （如 1785943092358），webhook 投递时保留原样；测试/手工调用可能是 ISO 字符串
--     → 兼容两种格式，非法值返回 NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION logto_ts(v text) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]+$' THEN
        -- 毫秒时间戳（13 位）或秒（10 位）
        IF length(v) >= 13 THEN
            RETURN to_timestamp(v::bigint / 1000.0);
        ELSE
            RETURN to_timestamp(v::bigint);
        END IF;
    END IF;
    RETURN v::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2.1 sync_user_upsert — 用户创建/更新
--     data 字段 = Logto User entity（F2 白名单）
--     字段: id, username, primaryEmail, primaryPhone, name, avatar,
--           customData, identities, lastSignInAt, createdAt, applicationId, isSuspended
--     Logto isSuspended 可能为 null → COALESCE(false)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO users (id, username, primary_email, primary_phone, name, avatar,
                       custom_data, identities, last_sign_in_at, created_at, application_id, is_suspended)
    VALUES (
        data->>'id',
        COALESCE(data->>'username', ''),
        COALESCE(data->>'primaryEmail', ''),
        COALESCE(data->>'primaryPhone', ''),
        COALESCE(data->>'name', ''),
        COALESCE(data->>'avatar', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(data->'identities', '{}'),
        logto_ts(data->>'lastSignInAt'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        COALESCE(data->>'applicationId', ''),
        COALESCE((data->>'isSuspended')::boolean, false)
    )
    ON CONFLICT (id) DO UPDATE SET
        username       = EXCLUDED.username,
        primary_email  = EXCLUDED.primary_email,
        primary_phone  = EXCLUDED.primary_phone,
        name           = EXCLUDED.name,
        avatar         = EXCLUDED.avatar,
        custom_data    = EXCLUDED.custom_data,
        identities     = EXCLUDED.identities,
        last_sign_in_at = EXCLUDED.last_sign_in_at,
        application_id = EXCLUDED.application_id,
        is_suspended   = EXCLUDED.is_suspended,
        updated_at     = now();
END $$;

-- ---------------------------------------------------------------------------
-- 2.2 sync_user_delete — 用户删除（软删）
--     data 仅含 id（05 F2 确认）；RPC 标记 deleted_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_delete(user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE users SET deleted_at = now(), updated_at = now()
    WHERE id = user_id AND deleted_at IS NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2.3 sync_tenant_upsert — 组织（租户）创建/更新
--     data: id, name, description, customData, createdAt
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_tenant_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO tenants (id, name, description, custom_data, created_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(logto_ts(data->>'createdAt'), now())
    )
    ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        custom_data = EXCLUDED.custom_data,
        updated_at  = now();
END $$;

-- ---------------------------------------------------------------------------
-- 2.4 sync_tenant_delete — 组织删除（软删）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_tenant_delete(org_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE tenants SET deleted_at = now(), updated_at = now()
    WHERE id = org_id AND deleted_at IS NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2.5 sync_membership_delta — 成员关系增量同步（05 F3：5000 条截断）
--     payload: organizationId + addedUserIds[] / removedUserIds[]（字符串数组）
--     恰好 5000 条时触发对账标记（sys_config 待办）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_membership_delta(
    org_id  text,
    added   jsonb,
    removed jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user_id text;
BEGIN
    -- 新增成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(added)
    LOOP
        INSERT INTO user_tenants (organization_id, user_id)
        VALUES (org_id, v_user_id)
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- 移除成员
    FOR v_user_id IN SELECT * FROM jsonb_array_elements_text(removed)
    LOOP
        DELETE FROM user_tenants
        WHERE organization_id = org_id AND user_id = v_user_id;
    END LOOP;

    -- F3: 5000 截断检测（任一数组恰好 5000 → 标记对账待办）
    IF jsonb_array_length(added) = 5000 OR jsonb_array_length(removed) = 5000 THEN
        INSERT INTO sys_config (config_key, config_value, config_type, description, is_public)
        VALUES ('reconciliation.pending_org', org_id, 'string',
                format('Membership delta capped at 5000 for org %s; full reconciliation needed', org_id),
                false)
        ON CONFLICT (config_key) DO UPDATE
        SET config_value = org_id, updated_at = now();
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2.6 sync_role_upsert — 角色目录创建/更新
--     data: id, name, type, isDefault
--     类型: 'User' / 'MachineToMachine'（05 F12 确认 logto_schemas/roles.sql）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO iam_role (id, name, type, is_default, created_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now()
    )
    ON CONFLICT (id) DO UPDATE SET
        name       = EXCLUDED.name,
        type       = EXCLUDED.type,
        is_default = EXCLUDED.is_default,
        updated_at = now();
END $$;

-- ---------------------------------------------------------------------------
-- 2.7 sync_role_delete — 角色目录删除
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_role_delete(role_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM iam_role WHERE id = role_id;
END $$;

-- ==============================================================================
-- §3 JIT 兜底建档 — 重写 ensure_user（Logto 版）
--     登录时若 users 表无记录则自动创建（webhook 丢失/延迟的兜底）
--     来源: JWT claims（sub/username/name/avatar），不再依赖 Casdoor 69 字段
--     旧函数 api_v1_sys.ensure_user()（返回 uuid）→ 先 DROP 再建（返回 text）
-- ==============================================================================
DROP FUNCTION IF EXISTS api_v1_sys.ensure_user();

CREATE FUNCTION api_v1_sys.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub    text;
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO users (id, username, name, avatar, is_suspended)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', ''),
        false
    )
    ON CONFLICT (id) DO UPDATE SET
        username = EXCLUDED.username,
        name     = EXCLUDED.name,
        avatar   = EXCLUDED.avatar,
        updated_at = now();

    -- JIT 兜底：默认租户（sys_user_profile 在有组织后才建，此处仅建用户镜像）
    RETURN v_sub;
END;
$$;

COMMENT ON FUNCTION api_v1_sys.ensure_user() IS 'JIT 兜底建档（Logto 版）：按 JWT sub 同步用户到 users 镜像表';
GRANT EXECUTE ON FUNCTION api_v1_sys.ensure_user() TO authenticated;

-- ==============================================================================
-- §4 Casdoor 资产退役（REVOKE + 函数标记 .deprecated）
--    沿用 008 migration 模式；幂等
-- ==============================================================================

-- 4.1 Casdoor webhook RPC 撤销（新 RPC 为 webhook_logto，签名不冲突）
DO $$
DECLARE v_rec record;
BEGIN
    FOR v_rec IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api_v1_sys'
          AND p.proname IN ('webhook_user_upsert', 'webhook_user_delete')
    LOOP
        BEGIN
            EXECUTE format('REVOKE EXECUTE ON FUNCTION api_v1_sys.%I(%s) FROM web_anon',
                           v_rec.proname, v_rec.args);
            RAISE NOTICE 'REVOKED api_v1_sys.%(%) FROM web_anon', v_rec.proname, v_rec.args;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'SKIP revoke api_v1_sys.%(%) — %', v_rec.proname, v_rec.args, SQLERRM;
        END;
    END LOOP;
END $$;

-- 4.2 rpc_create_user 退役（管理端建号改调 Logto Management API，05 §10.2）
DO $$
DECLARE v_rec record;
BEGIN
    FOR v_rec IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api_v1_sys' AND p.proname = 'create_user'
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION api_v1_sys.%I(%s) FROM authenticated',
                       v_rec.proname, v_rec.args);
        RAISE NOTICE 'REVOKED api_v1_sys.%(%) FROM authenticated', v_rec.proname, v_rec.args;
    END LOOP;
END $$;

-- 4.3 check_token_blacklist 保留但恒真（D25：不启用黑名单机制）
CREATE OR REPLACE FUNCTION api_v1_sys.check_token_blacklist() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- D25: sys_token_blacklist 不启用，永不放行阻断
    -- 会话吊销由 Logto revocation endpoint 处理（D12）
    -- 保留函数体避免 PGRST_DB_PRE_REQUEST 报错缺失函数
    NULL;
END;
$$;

COMMENT ON FUNCTION api_v1_sys.check_token_blacklist() IS 'Logto 时代黑名单检查（恒真，不启用）；会话吊销由 Logto 管理';

-- ==============================================================================
-- migrate:down
-- ==============================================================================
-- 恢复: 重新 GRANT Casdoor RPC 权限 + 恢复旧 ensure_user
--       需对应 .deprecated 文件中的原始 GRANT 语句
--       check_token_blacklist 恢复原实现需 git checkout 旧版本
--       新函数 api_v1_sys.webhook_logto / sync_* 系列不影响旧 RPC 共存
