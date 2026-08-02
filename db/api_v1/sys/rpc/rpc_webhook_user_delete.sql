-- db/api_v1/sys/rpc/rpc_webhook_user_delete.sql
-- Casdoor Webhook 接收 RPC：delete-user 事件 → 软删用户（Phase 1, D2）
-- 鉴权: 与 webhook_user_upsert 相同（X-Webhook-Secret）
-- 签名设计: (event text, user jsonb) —— 匹配 Casdoor 原始 payload（同 upsert）
-- 语义: mirror.isdeleted='true'（触发器派生 deleted_at）+ profile.deleted_at
--       （Casdoor 软删；硬删场景由对账/人工处理，FK 数据保护）

CREATE OR REPLACE FUNCTION api_v1_sys.webhook_user_delete(
    event text,
    "user" jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_secret  text;
    v_header  text;
    v_user    jsonb := "user";
    v_sub     uuid;
BEGIN
    -- 1. 鉴权
    SELECT key_value INTO v_secret FROM sys_secret WHERE key_name = 'casdoor_webhook_secret';
    IF v_secret IS NULL OR v_secret = '' THEN
        RAISE EXCEPTION 'Webhook secret not configured' USING ERRCODE = 'P0098';
    END IF;
    v_header := current_setting('request.headers', true)::json->>'x-webhook-secret';
    IF v_header IS DISTINCT FROM v_secret THEN
        RAISE EXCEPTION 'Invalid webhook secret' USING ERRCODE = 'P0098';
    END IF;

    -- 2. 解析
    IF v_user IS NULL OR v_user = 'null'::jsonb THEN
        RAISE EXCEPTION 'Invalid payload: missing user' USING ERRCODE = 'P0001';
    END IF;
    v_sub := NULLIF(v_user->>'id', '')::uuid;
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Invalid payload: missing user.id' USING ERRCODE = 'P0001';
    END IF;

    -- 3. 软删（镜像 + 业务档案）
    UPDATE casdoor_user_mirror SET isdeleted = 'true' WHERE id = v_sub;
    UPDATE sys_user_profile SET deleted_at = now() WHERE user_id = v_sub AND deleted_at IS NULL;

    RETURN FOUND;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.webhook_user_delete(text, jsonb) IS 'Casdoor webhook 用户删除接收（Phase 1, D2；参数名匹配原始 payload）';
GRANT EXECUTE ON FUNCTION api_v1_sys.webhook_user_delete(text, jsonb) TO web_anon;
