-- db/api_v1/sys/rpc/rpc_webhook_user_upsert.sql
-- Casdoor Webhook 接收 RPC：new-user / add-user / update-user 事件 → upsert 用户
-- 方案 C 重写（04.8 §5.2）：签名 (event text, "user" jsonb) → (payload jsonb) 整包接收
-- 重写原因（C7/§14.2）：真实 payload = Record 结构，无 event 字段；
--   user 是操作者用户名（字符串）；用户对象在 object（JSON 字符串，需二次解析）。
--   Phase 1 的 (event, user) 参数假设与真实 payload 不匹配，从未被命中。
-- 守卫：① X-Webhook-Secret 鉴权 ② action 校验 ③ response 成败守卫（H4）
-- 语义：失败/越权请求（response 非 status:"ok"）静默跳过，不落库（避免重试风暴）；
--       鉴权/结构错误 RAISE（HTTP 500 → Casdoor 重试，属可恢复场景）。

CREATE OR REPLACE FUNCTION api_v1_sys.webhook_user_upsert(payload jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_secret   text;
    v_header   text;
    v_action   text;
    v_response text;
    v_user     jsonb;
    v_sub      uuid;
    v_tenant   uuid;
BEGIN
    -- ① 鉴权（webhook 端点公开，必须校验共享密钥）
    SELECT key_value INTO v_secret FROM sys_secret WHERE key_name = 'casdoor_webhook_secret';
    IF v_secret IS NULL OR v_secret = '' THEN
        RAISE EXCEPTION 'Webhook secret not configured' USING ERRCODE = 'P0098';
    END IF;
    v_header := current_setting('request.headers', true)::json->>'x-webhook-secret';
    IF v_header IS DISTINCT FROM v_secret THEN
        RAISE EXCEPTION 'Invalid webhook secret' USING ERRCODE = 'P0098';
    END IF;

    -- ② action 校验（new-user 为 signup 特判，object 为 DB 拉取的全量用户对象；
    --    add-user/update-user 的 object 为请求体原文）
    v_action := payload->>'action';
    IF v_action IS NULL OR v_action NOT IN ('new-user', 'add-user', 'update-user') THEN
        RAISE EXCEPTION 'Unsupported action: %', v_action USING ERRCODE = 'P0001';
    END IF;

    -- ③ 成败守卫（H4）：response 含 status:"ok" 才落库；失败/越权请求静默跳过
    v_response := payload->>'response';
    IF v_response IS NULL OR strpos(v_response, 'status:"ok"') = 0 THEN
        RETURN NULL;
    END IF;

    -- ④ 解析 object（Record.Object 为 JSON 字符串，二次解析）
    v_user := (payload->>'object')::jsonb;
    IF v_user IS NULL OR v_user = 'null'::jsonb THEN
        RAISE EXCEPTION 'Invalid payload: missing object' USING ERRCODE = 'P0001';
    END IF;
    v_sub := NULLIF(v_user->>'id', '')::uuid;
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Invalid payload: missing user.id' USING ERRCODE = 'P0001';
    END IF;

    -- ⑤ 落库：upsert 镜像表核心字段（与 Phase 1 逻辑一致；全量字段由 Database Syncer/JIT 对账）
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

    -- ⑥ 业务档案（默认租户，JIT 兜底同款）
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

COMMENT ON FUNCTION api_v1_sys.webhook_user_upsert(jsonb) IS 'Casdoor webhook 用户新增/更新接收（方案 C 重写：整包 payload + response 成败守卫）';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_user_upsert(jsonb) TO web_anon;

-- 移除 Phase 1 旧签名（(event text, "user" jsonb)），避免 PostgREST 暴露两个版本
DROP FUNCTION IF EXISTS api_v1_sys.webhook_user_upsert(text, jsonb);
