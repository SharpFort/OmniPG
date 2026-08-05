-- db/api_v1/sys/rpc/rpc_ensure_user.sql
-- JIT 兜底建档 RPC（Logto 版，T7 同步 018 迁移）
-- 读取 Logto JWT claims（sub/username/name/avatar/organization_id），
-- upsert users 镜像表；组织 token 携带 organization_id 时补建 user_profile（租户归属）。
-- 触发时机: 前端登录回调后调用（webhook 丢失/延迟时的兜底，保证 RLS 可用）

CREATE OR REPLACE FUNCTION api_v1_sys.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub    text;
    v_org    text;
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

    -- JIT 兜底：组织 token 携带 organization_id 时补建 profile（租户归属）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;
    END IF;

    RETURN v_sub;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_sys.ensure_user() TO authenticated;
