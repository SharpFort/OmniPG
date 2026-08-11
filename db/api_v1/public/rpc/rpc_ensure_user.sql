-- db/api_v1/public/rpc/rpc_ensure_user.sql
-- JIT 兜底建档 RPC（Logto 版，T7 同步 018 迁移；035 增加 user_role 镜像 JIT 覆盖）
-- 读取 Logto JWT claims（sub/username/name/avatar/organization_id/roles），
-- 补建 users 镜像表 + user_profile（租户归属）+ user_role（角色分配镜像）。
-- 触发时机: 前端登录回调后调用（webhook 丢失/延迟时的兜底，保证 RLS 可用）
-- 035: user_role 全量覆盖 = Logto 权威经 JWT claims 随登录推送（替代 rpc_sync_user_roles，
--      已删除——Logto 无"用户-角色绑定"webhook 事件，登录 JWT 是唯一推送通道）
-- N7（2026-08-11）: users / user_profile 改为"仅缺失补建、不覆盖 webhook 权威值"——
--      旧版 ON CONFLICT DO UPDATE 以空串覆盖 username/name/avatar（claims 脚本仅注入
--      roles/pg_role，不含用户资料字段）、profile tenant_id 随当前组织 token 漂移、
--      is_suspended 不受 JIT 管理（封禁经 User.SuspensionStatus.Updated 同步，P1 D7）。

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

    -- N7: users 镜像完全由 webhook（User.*）维护，JIT 仅缺失补建；
    --   补建行取 claims 可用值（现状为空串，等 webhook/对账回填）
    INSERT INTO users (id, username, name, avatar)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', '')
    )
    ON CONFLICT (id) DO NOTHING;

    -- N7: profile 仅在无记录时补建（tenant 归属 = 首次观察到的组织上下文，不再漂移）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;

    -- 035: user_role 分配镜像 JIT 覆盖（claims roles = Logto 当前权威，全量覆盖；
    --      增量对齐保护 created_at 为 P1 D6 项，另行实施）
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
COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像覆盖（035: user_role 随 claims 全量覆盖，替代 rpc_sync_user_roles；N7: users/profile 仅缺失补建，不覆盖 webhook 权威值）';
GRANT EXECUTE ON FUNCTION api_v1_public.ensure_user() TO authenticated;
