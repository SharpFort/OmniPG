-- db/api_v1/public/rpc/rpc_ensure_user.sql
-- JIT 兜底建档 RPC（Logto 版，T7 同步 018 迁移；035 增加 user_role 镜像 JIT 覆盖）
-- 读取 Logto JWT claims（sub/username/name/avatar/organization_id/roles），
-- upsert users 镜像表 + user_profile（租户归属）+ user_role（角色分配镜像）。
-- 触发时机: 前端登录回调后调用（webhook 丢失/延迟时的兜底，保证 RLS 可用）
-- 035: user_role 全量覆盖 = Logto 权威经 JWT claims 随登录推送（替代 rpc_sync_user_roles，
--      已删除——Logto 无"用户-角色绑定"webhook 事件，登录 JWT 是唯一推送通道）

CREATE OR REPLACE FUNCTION api_v1_public.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub    text;
    v_org    text;
    v_roles  text[];
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

    -- 035: user_role 分配镜像 JIT 覆盖（claims roles = Logto 当前权威，全量覆盖）
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_claims->'roles'));
    DELETE FROM user_role WHERE user_id = v_sub;
    IF v_roles IS NOT NULL AND cardinality(v_roles) > 0 THEN
        INSERT INTO user_role (user_id, role_code)
        SELECT v_sub, g FROM unnest(v_roles) AS g
        ON CONFLICT (user_id, role_code) DO NOTHING;
    END IF;

    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像覆盖（035: user_role 随 claims 全量覆盖，替代 rpc_sync_user_roles）';
GRANT EXECUTE ON FUNCTION api_v1_public.ensure_user() TO authenticated;
