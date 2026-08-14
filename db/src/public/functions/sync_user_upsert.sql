-- src/public/functions/sync_user_upsert.sql
-- FUNCTION: public.sync_user_upsert（17 号文档归位：迁移 051_logto_guard_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 051_logto_guard_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION sync_user_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO users (id, username, primary_email, primary_phone, name, avatar,
                       custom_data, identities, last_sign_in_at, created_at, application_id,
                       is_suspended, profile, sso_identities, updated_at, logto_updated_at)
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
        v_ts, v_ts
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
        updated_at      = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE users.logto_updated_at IS NULL                       -- 存量兼容（首次同步）
       OR EXCLUDED.logto_updated_at >= users.logto_updated_at; -- 乱序守护（N18）
END $$;
