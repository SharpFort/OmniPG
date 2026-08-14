-- src/public/functions/sync_role_upsert.sql
-- FUNCTION: public.sync_role_upsert（17 号文档归位：迁移 051_logto_guard_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 051_logto_guard_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION sync_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ts timestamptz := COALESCE(logto_ts(data->>'updatedAt'), now());
BEGIN
    INSERT INTO role (id, name, description, type, is_default, created_at, updated_at, logto_updated_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'description', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now(),
        v_ts, v_ts
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        description      = EXCLUDED.description,
        type             = EXCLUDED.type,
        is_default       = EXCLUDED.is_default,
        updated_at       = EXCLUDED.updated_at,
        logto_updated_at = EXCLUDED.logto_updated_at
    WHERE role.logto_updated_at IS NULL
       OR EXCLUDED.logto_updated_at >= role.logto_updated_at;
END $$;
