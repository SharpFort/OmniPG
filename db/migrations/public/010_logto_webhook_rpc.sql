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
-- ---------------------------------------------------------------------------
-- 2.1 sync_user_upsert — 用户创建/更新
--     data 字段 = Logto User entity（F2 白名单）
--     字段: id, username, primaryEmail, primaryPhone, name, avatar,
--           customData, identities, lastSignInAt, createdAt, applicationId, isSuspended
--     Logto isSuspended 可能为 null → COALESCE(false)
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.2 sync_user_delete — 用户删除（软删）
--     data 仅含 id（05 F2 确认）；RPC 标记 deleted_at
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.3 sync_tenant_upsert — 组织（租户）创建/更新
--     data: id, name, description, customData, createdAt
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.4 sync_tenant_delete — 组织删除（软删）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.5 sync_membership_delta — 成员关系增量同步（05 F3：5000 条截断）
--     payload: organizationId + addedUserIds[] / removedUserIds[]（字符串数组）
--     恰好 5000 条时触发对账标记（sys_config 待办）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.6 sync_role_upsert — 角色目录创建/更新
--     data: id, name, type, isDefault
--     类型: 'User' / 'MachineToMachine'（05 F12 确认 logto_schemas/roles.sql）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 2.7 sync_role_delete — 角色目录删除
-- ---------------------------------------------------------------------------
-- ==============================================================================
-- §3 JIT 兜底建档 — 重写 ensure_user（Logto 版）
--     登录时若 users 表无记录则自动创建（webhook 丢失/延迟的兜底）
--     来源: JWT claims（sub/username/name/avatar），不再依赖 Casdoor 69 字段
--     旧函数 api_v1_sys.ensure_user()（返回 uuid）→ 先 DROP 再建（返回 text）
-- ==============================================================================





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


-- ==============================================================================
-- migrate:down
-- ==============================================================================
-- 恢复: 重新 GRANT Casdoor RPC 权限 + 恢复旧 ensure_user
--       需对应 .deprecated 文件中的原始 GRANT 语句
--       check_token_blacklist 恢复原实现需 git checkout 旧版本
--       新函数 api_v1_sys.webhook_logto / sync_* 系列不影响旧 RPC 共存
