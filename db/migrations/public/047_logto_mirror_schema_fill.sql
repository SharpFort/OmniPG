-- =============================================================================
-- 047_logto_mirror_schema_fill.sql — D2 镜像表结构补齐（33 号文档 §9 D2）
-- =============================================================================
-- 背景: 2026-08-11 用户拍板——role 补 description；users 补 profile/ssoIdentities；
--   webhook 推送字段入库阶段全部接收；updated_at 映射进 sync_*。
-- 字段来源核实（官方 webhooks-request 页 + 源码 userInfoSelectFields）:
--   - webhook UserEntity 13 字段不含 profile/ssoIdentities/updatedAt
--     → 两列默认 '{}'（webhook 阶段恒空），唯一数据来源 = 对账任务（D9）注入；
--   - updatedAt 仅在 Management API 返回 → COALESCE(logto_ts(data->>'updatedAt'), now())
--     （webhook 推送时落本地时间，对账 payload 携带时落权威时间）
-- 幂等: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / GRANT 可重放
-- 依赖: logto_ts（010）、sync_user_upsert/sync_role_upsert/sync_tenant_upsert（010 初版，本迁移重写）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 列补齐
-- ---------------------------------------------------------------------------
ALTER TABLE public.role ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
COMMENT ON COLUMN public.role.description IS 'Logto Role.description（webhook/对账推送）';

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS profile jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS sso_identities jsonb NOT NULL DEFAULT '{}';
COMMENT ON COLUMN public.users.profile IS 'Logto User.profile（OIDC 标准 claims；仅 Management API 返回，对账任务 D9 注入）';
COMMENT ON COLUMN public.users.sso_identities IS 'Logto User.ssoIdentities（企业 SSO 身份；仅 Management API 返回，对账任务 D9 注入）';

-- ---------------------------------------------------------------------------
-- §2 sync_user_upsert 重写（D2: +profile/sso_identities 列 + updatedAt 映射）
--     data 字段 = Logto User entity（webhook 13 字段；对账 payload 可含 profile/
--     ssoIdentities/updatedAt——Management API 返回）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_user_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO users (id, username, primary_email, primary_phone, name, avatar,
                       custom_data, identities, last_sign_in_at, created_at, application_id,
                       is_suspended, profile, sso_identities, updated_at)
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
        COALESCE((data->>'isSuspended')::boolean, false),
        COALESCE(data->'profile', '{}'),
        COALESCE(data->'ssoIdentities', '{}'),
        COALESCE(logto_ts(data->>'updatedAt'), now())
    )
    ON CONFLICT (id) DO UPDATE SET
        username        = EXCLUDED.username,
        primary_email   = EXCLUDED.primary_email,
        primary_phone   = EXCLUDED.primary_phone,
        name            = EXCLUDED.name,
        avatar          = EXCLUDED.avatar,
        custom_data     = EXCLUDED.custom_data,
        identities      = EXCLUDED.identities,
        last_sign_in_at = EXCLUDED.last_sign_in_at,
        application_id  = EXCLUDED.application_id,
        is_suspended    = EXCLUDED.is_suspended,
        profile         = EXCLUDED.profile,
        sso_identities  = EXCLUDED.sso_identities,
        updated_at      = EXCLUDED.updated_at;
END $$;
COMMENT ON FUNCTION sync_user_upsert(jsonb) IS 'Logto 用户镜像 upsert（047 D2: +profile/sso_identities 列、updatedAt 映射；对账 payload 可注入 Management API 专属字段）';

-- ---------------------------------------------------------------------------
-- §3 sync_role_upsert 重写（D2: +description 列 + updatedAt 映射）
--     data: id, name, description, type, isDefault（webhook/对账；updatedAt 可选）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO role (id, name, description, type, is_default, created_at, updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now(),
        COALESCE(logto_ts(data->>'updatedAt'), now())
    )
    ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        type        = EXCLUDED.type,
        is_default  = EXCLUDED.is_default,
        updated_at  = EXCLUDED.updated_at;
END $$;
COMMENT ON FUNCTION sync_role_upsert(jsonb) IS 'Logto 角色目录镜像 upsert（047 D2: +description 列、updatedAt 映射）';

-- ---------------------------------------------------------------------------
-- §4 sync_tenant_upsert 重写（D2: updatedAt 映射）
--     data: id, name, description, customData, createdAt, updatedAt（可选）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_tenant_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO tenants (id, name, description, custom_data, created_at, updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->'customData', '{}'),
        COALESCE(logto_ts(data->>'createdAt'), now()),
        COALESCE(logto_ts(data->>'updatedAt'), now())
    )
    ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        custom_data = EXCLUDED.custom_data,
        updated_at  = EXCLUDED.updated_at;
END $$;
COMMENT ON FUNCTION sync_tenant_upsert(jsonb) IS 'Logto 组织镜像 upsert（047 D2: updatedAt 映射）';

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ucols int; v_rcol int; v_fn int;
BEGIN
    SELECT count(*) INTO v_ucols FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users'
      AND column_name IN ('profile', 'sso_identities');
    SELECT count(*) INTO v_rcol FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'role'
      AND column_name = 'description';
    SELECT count(*) INTO v_fn FROM pg_proc
    WHERE proname IN ('sync_user_upsert', 'sync_role_upsert', 'sync_tenant_upsert');
    RAISE NOTICE '047: users新增列=% role.description=% sync函数=%（期望 2/1/3）', v_ucols, v_rcol, v_fn;
    IF v_ucols <> 2 OR v_rcol <> 1 OR v_fn <> 3 THEN
        RAISE EXCEPTION '047 验证失败';
    END IF;
    RAISE NOTICE '047: 全部验证通过';
END $$;
