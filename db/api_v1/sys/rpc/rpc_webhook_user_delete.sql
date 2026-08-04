-- db/api_v1/sys/rpc/rpc_webhook_user_delete.sql
-- Casdoor Webhook 接收 RPC：delete-user 事件 → 软删用户（镜像 + 业务档案）
-- 方案 C 重写（04.8 §5.2）：签名 (event text, "user" jsonb) → (payload jsonb) 整包接收
-- 守卫：① X-Webhook-Secret 鉴权 ② action 校验 ③ response 成败守卫（H4）
-- 用户标识解析：优先 object.id；object 缺失/非 JSON（DELETE 请求可能无 body）时，
--   从 requestUri 解析 ?id=owner%2Fname（URL-decode 后按 name 查镜像表）。
-- 语义：软删（mirror.isdeleted='true'，触发器派生 deleted_at；profile.deleted_at）；
--       硬删场景由对账/人工处理（FK 数据保护）。

CREATE OR REPLACE FUNCTION api_v1_sys.webhook_user_delete(payload jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_secret   text;
    v_header   text;
    v_action   text;
    v_response text;
    v_obj_text text;
    v_user     jsonb;
    v_uri      text;
    v_key      text;
    v_sub      uuid;
BEGIN
    -- ① 鉴权
    SELECT key_value INTO v_secret FROM sys_secret WHERE key_name = 'casdoor_webhook_secret';
    IF v_secret IS NULL OR v_secret = '' THEN
        RAISE EXCEPTION 'Webhook secret not configured' USING ERRCODE = 'P0098';
    END IF;
    v_header := current_setting('request.headers', true)::json->>'x-webhook-secret';
    IF v_header IS DISTINCT FROM v_secret THEN
        RAISE EXCEPTION 'Invalid webhook secret' USING ERRCODE = 'P0098';
    END IF;

    -- ② action 校验
    v_action := payload->>'action';
    IF v_action IS NULL OR v_action <> 'delete-user' THEN
        RAISE EXCEPTION 'Unsupported action: %', v_action USING ERRCODE = 'P0001';
    END IF;

    -- ③ 成败守卫（H4）
    v_response := payload->>'response';
    IF v_response IS NULL OR strpos(v_response, 'status:"ok"') = 0 THEN
        RETURN FALSE;
    END IF;

    -- ④ 解析用户标识：优先 object.id；object 为空/非 JSON 时从 requestUri 解析
    v_obj_text := payload->>'object';
    IF v_obj_text IS NOT NULL AND btrim(v_obj_text) <> '' AND v_obj_text <> 'null' THEN
        BEGIN
            v_user := v_obj_text::jsonb;
            v_sub  := NULLIF(v_user->>'id', '')::uuid;
        EXCEPTION WHEN OTHERS THEN
            v_user := NULL;  -- object 非 JSON（如 DELETE 无 body 场景），走 requestUri
        END;
    END IF;

    IF v_sub IS NULL THEN
        v_uri := payload->>'requestUri';          -- 形如 /api/delete-user?id=omnipg%2Falice
        v_key := split_part(COALESCE(v_uri, ''), 'id=', 2);
        v_key := replace(replace(v_key, '%2F', '/'), '%2f', '/');
        IF v_key ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
            v_sub := v_key::uuid;
        ELSIF v_key <> '' THEN
            SELECT id INTO v_sub FROM casdoor_user_mirror
            WHERE name IN (split_part(v_key, '/', 2), v_key)
            ORDER BY (isdeleted = 'true')  -- 优先未删除行
            LIMIT 1;
        END IF;
    END IF;

    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Invalid payload: cannot resolve user id' USING ERRCODE = 'P0001';
    END IF;

    -- ⑤ 软删（镜像 + 业务档案）
    UPDATE casdoor_user_mirror SET isdeleted = 'true' WHERE id = v_sub;
    UPDATE sys_user_profile SET deleted_at = now() WHERE user_id = v_sub AND deleted_at IS NULL;

    RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION api_v1_sys.webhook_user_delete(jsonb) IS 'Casdoor webhook 用户删除接收（方案 C 重写：整包 payload + response 成败守卫 + requestUri 兜底解析）';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_user_delete(jsonb) TO web_anon;

-- 移除 Phase 1 旧签名（(event text, "user" jsonb)），避免 PostgREST 暴露两个版本
DROP FUNCTION IF EXISTS api_v1_sys.webhook_user_delete(text, jsonb);
