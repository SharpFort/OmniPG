-- db/api_v1/sys/rpc/rpc_webhook_user_upsert.sql
-- Casdoor Webhook 接收 RPC：new-user / update-user 事件 → upsert 用户（Phase 1, D2）
-- 鉴权: 请求头 X-Webhook-Secret 必须等于 sys_secret 中 casdoor_webhook_secret（Phase 2 配置）
-- 签名设计: (event text, user jsonb) —— PostgREST 按 body 键自动匹配参数，
--           Casdoor webhook 原始 payload {"event":"...","user":{...}} 可直接 POST
-- 说明: 仅同步核心字段（id/name/displayName/email/phone/avatar/状态），
--       全量字段由 Casdoor Database Syncer 对账补齐（D2 组合方案）

CREATE OR REPLACE FUNCTION api_v1_sys.webhook_user_upsert(
    event text,
    "user" jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_secret      text;
    v_header      text;
    v_user        jsonb := "user";
    v_sub         uuid;
    v_tenant      uuid;
BEGIN
    -- 1. 鉴权（webhook 端点公开，必须校验共享密钥）
    SELECT key_value INTO v_secret FROM sys_secret WHERE key_name = 'casdoor_webhook_secret';
    IF v_secret IS NULL OR v_secret = '' THEN
        RAISE EXCEPTION 'Webhook secret not configured' USING ERRCODE = 'P0098';
    END IF;
    v_header := current_setting('request.headers', true)::json->>'x-webhook-secret';
    IF v_header IS DISTINCT FROM v_secret THEN
        RAISE EXCEPTION 'Invalid webhook secret' USING ERRCODE = 'P0098';
    END IF;

    -- 2. 解析 user 对象
    IF v_user IS NULL OR v_user = 'null'::jsonb THEN
        RAISE EXCEPTION 'Invalid payload: missing user' USING ERRCODE = 'P0001';
    END IF;
    v_sub := NULLIF(v_user->>'id', '')::uuid;
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Invalid payload: missing user.id' USING ERRCODE = 'P0001';
    END IF;

    -- 3. upsert 镜像表核心字段
    INSERT INTO casdoor_user_mirror (id, name, displayname, email, phone, avatar,
                                     isforbidden, isdeleted, isadmin,
                                     score, signupapplication)
    VALUES (
        v_sub,
        COALESCE(v_user->>'name', ''),
        COALESCE(v_user->>'displayName', ''),
        COALESCE(v_user->>'email', ''),
        COALESCE(v_user->>'phone', ''),
        COALESCE(v_user->>'avatar', ''),
        COALESCE(v_user->>'isForbidden', 'false'),
        COALESCE(v_user->>'isDeleted', 'false'),
        COALESCE(v_user->>'isAdmin', 'false'),
        COALESCE(v_user->>'score', '0'),
        COALESCE(v_user->>'signupApplication', '')
    )
    ON CONFLICT (id) DO UPDATE SET
        name             = EXCLUDED.name,
        displayname      = EXCLUDED.displayname,
        email            = EXCLUDED.email,
        phone            = EXCLUDED.phone,
        avatar           = EXCLUDED.avatar,
        isforbidden      = EXCLUDED.isforbidden,
        isdeleted        = EXCLUDED.isdeleted,
        isadmin          = EXCLUDED.isadmin,
        score            = EXCLUDED.score,
        signupapplication = EXCLUDED.signupapplication;

    -- 4. 业务档案（D5: 默认租户）
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
COMMENT ON FUNCTION api_v1_sys.webhook_user_upsert(text, jsonb) IS 'Casdoor webhook 用户新增/更新接收（Phase 1, D2；参数名匹配原始 payload）';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_user_upsert(text, jsonb) TO web_anon;
