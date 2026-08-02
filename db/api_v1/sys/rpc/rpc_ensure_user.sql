-- db/api_v1/sys/rpc/rpc_ensure_user.sql
-- JIT 兜底建档 RPC（Phase 1, D2: 登录时若 mirror/profile 无记录则自动创建）
-- 读取 Casdoor JWT claims（sub/name/displayName/email/phone/avatar），
-- upsert casdoor_user_mirror + sys_user_profile（默认租户）。
-- 触发时机: 前端登录回调后调用（webhook 丢失/延迟时的兜底，保证 RLS 可用）

CREATE OR REPLACE FUNCTION api_v1_sys.ensure_user()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims   jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub      uuid;
    v_tenant   uuid;
BEGIN
    -- 1. 提取 sub（Casdoor 用户 UUID == casdoor_user_mirror.id）
    v_sub := NULLIF(v_claims->>'sub', '')::uuid;
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    -- 2. upsert 镜像表基础字段（其余字段由 Casdoor Syncer 对账补全）
    INSERT INTO casdoor_user_mirror (id, name, displayname, email, phone, avatar,
                                     isforbidden, isdeleted)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'displayName', ''),
        COALESCE(v_claims->>'email', ''),
        COALESCE(v_claims->>'phone', ''),
        COALESCE(v_claims->>'avatar', ''),
        'false', 'false'
    )
    ON CONFLICT (id) DO UPDATE SET
        name        = EXCLUDED.name,
        displayname = EXCLUDED.displayname,
        email       = EXCLUDED.email,
        phone       = EXCLUDED.phone,
        avatar      = EXCLUDED.avatar;

    -- 3. 业务档案（D5: 默认租户;已建档则不动）
    SELECT id INTO v_tenant
    FROM sys_tenant
    WHERE tenant_code = 'default' AND deleted_at IS NULL
    ORDER BY created_at
    LIMIT 1;

    INSERT INTO sys_user_profile (user_id, tenant_id)
    VALUES (v_sub, v_tenant)
    ON CONFLICT (user_id) DO NOTHING;

    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.ensure_user() IS 'JIT 兜底建档：按 JWT sub 同步用户到 mirror/profile（Phase 1）';
GRANT EXECUTE ON FUNCTION api_v1_sys.ensure_user() TO authenticated;
