-- db/api_v1/public/rpc/rpc_ensure_user.sql
-- JIT 兜底建档 RPC（Logto 版，T7 同步 018 迁移；035 增加 user_role 镜像 JIT 覆盖）
-- 读取 Logto JWT claims（sub/username/name/avatar/organization_id/roles/global_roles/org_roles），
-- 补建 users 镜像表 + user_profile（租户归属）+ user_role（角色分配镜像）。
-- 触发时机: 前端登录回调后调用（webhook 丢失/延迟时的兜底，保证 RLS 可用）
-- 035: user_role 全量覆盖 = Logto 权威经 JWT claims 随登录推送（替代 rpc_sync_user_roles，
--      已删除——Logto 无"用户-角色绑定"webhook 事件，登录 JWT 是唯一推送通道）
-- N7（2026-08-11）: users / user_profile 改为"仅缺失补建、不覆盖 webhook 权威值"——
--      旧版 ON CONFLICT DO UPDATE 以空串覆盖 username/name/avatar（claims 脚本仅注入
--      roles/pg_role，不含用户资料字段）、profile tenant_id 随当前组织 token 漂移、
--      is_suspended 不受 JIT 管理（封禁经 User.SuspensionStatus.Updated 同步，P1 D7）。
-- 049（2026-08-11）D5/D6: user_role 精确镜像——global/org 分段增量对齐（与迁移 049 一致）：
--      · 增量对齐：角色不变零写入、created_at 保留首次分配时间；
--      · 全局段（organization_id=''）：claims 恒有 global_roles（脚本注入，可为空）→ 空则清空；
--      · 组织段：仅当本次登录携带组织上下文（v_org 非空）时对齐——全局 token 登录
--        不清组织段（防多组织用户换上下文登录丢失镜像）；
--      · 兼容：claims 无 global_roles/org_roles（旧 token）→ 跳过（不写不删）；
--      · role_id 回填：role 镜像存在时按名取 id（LEFT JOIN），缺失为 NULL 等对账。
-- ⚠️ 本文件为权威源（apply-src 重放覆盖迁移层），必须与迁移 049 §2 逐字一致。

CREATE OR REPLACE FUNCTION api_v1_public.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims     jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub        text;
    v_org        text;
    v_global     text[];
    v_org_roles  text[];
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    -- N7: users 镜像完全由 webhook（User.*）维护，JIT 仅缺失补建（不覆盖权威值）
    INSERT INTO users (id, username, name, avatar)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', '')
    )
    ON CONFLICT (id) DO NOTHING;

    -- N7: profile 仅在无记录时补建（tenant 归属 = 首次观察到的组织上下文）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;

    -- D5/D6（049）: user_role 精确镜像——global/org 分段增量对齐
    --   · 增量对齐：角色不变零写入、created_at 保留首次分配时间；
    --   · 全局段（organization_id=''）：claims 恒有 global_roles（脚本注入，可为空）→ 空则清空；
    --   · 组织段：仅当本次登录携带组织上下文（v_org 非空）时对齐——全局 token 登录
    --     不清组织段（防多组织用户换上下文登录丢失镜像）；
    --   · 兼容：claims 无 global_roles/org_roles（旧 token）→ 跳过（不写不删）；
    --   · role_id 回填：role 镜像存在时按名取 id（LEFT JOIN），缺失为 NULL 等对账。
    IF v_claims ? 'global_roles' THEN
        v_global := ARRAY(SELECT jsonb_array_elements_text(v_claims->'global_roles'));
        INSERT INTO user_role (user_id, organization_id, role_code, role_id)
        SELECT v_sub, '', g, r.id
        FROM unnest(v_global) AS g
        LEFT JOIN role r ON r.name = g
        WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                          WHERE ur.user_id = v_sub
                            AND ur.organization_id = ''
                            AND ur.role_code = g);
        DELETE FROM user_role
        WHERE user_id = v_sub AND organization_id = ''
          AND role_code NOT IN (SELECT unnest(v_global));
    END IF;

    IF v_claims ? 'org_roles' THEN
        v_org_roles := ARRAY(SELECT jsonb_array_elements_text(v_claims->'org_roles'));
        IF v_org IS NOT NULL THEN
            INSERT INTO user_role (user_id, organization_id, role_code, role_id)
            SELECT v_sub, v_org, g, r.id
            FROM unnest(v_org_roles) AS g
            LEFT JOIN role r ON r.name = g
            WHERE NOT EXISTS (SELECT 1 FROM user_role ur
                              WHERE ur.user_id = v_sub
                                AND ur.organization_id = v_org
                                AND ur.role_code = g);
            DELETE FROM user_role
            WHERE user_id = v_sub AND organization_id = v_org
              AND role_code NOT IN (SELECT unnest(v_org_roles));
        END IF;
    END IF;

    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像精确对齐（035: user_role 随 claims 全量覆盖；049 D5/D6: global/org 分段增量对齐，角色不变零写入，保留 created_at，全局 token 不清 org 段）';
GRANT EXECUTE ON FUNCTION api_v1_public.ensure_user() TO authenticated;
