-- src/platform/functions/sync_login_log_write.sql
-- FUNCTION: platform.sync_login_log_write（D27: login_log 新增 tenant_id/organization_id 双列）

CREATE OR REPLACE FUNCTION sync_login_log_write(payload jsonb) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_user_id    text := payload->>'userId';
    v_username   text;
    v_ip         inet;
    v_agent      text := payload->>'userAgent';
    v_ts         timestamptz := logto_ts(payload->>'createdAt');
    v_login_type text;
BEGIN
    IF v_user_id IS NULL THEN RETURN; END IF;

    SELECT username INTO v_username FROM users WHERE id = v_user_id;

    BEGIN
        v_ip := (payload->>'userIp')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    -- identities 为 JSON null/非对象时按"无身份信息"处理（2026-11-19 修补）：
    -- 原 COALESCE 不替换 JSON null 标量，jsonb_each_text 会抛 22023
    SELECT key INTO v_login_type
    FROM jsonb_each_text(
        CASE WHEN jsonb_typeof(payload->'user'->'identities') = 'object'
             THEN payload->'user'->'identities' ELSE '{}'::jsonb END)
    LIMIT 1;

    INSERT INTO login_log
        (tenant_id, organization_id, user_id, username, login_type, result, ip, user_agent,
         region, logto_event, created_at)
    VALUES
        -- 租户优先取 webhook 载荷内的 tenantId（Logto 事件自带），
        -- 缺失时回退 current_logto_tenant_id()（webhook 会话无 JWT claims → 'default'）。
        -- ⚠ 残余风险（待 2d webhook 鉴权批收口）：tenantId 属调用方可控数据，
        -- rpc_webhook_logto 目前无调用方校验（S-C21），伪造合法租户 id 可污染他租户登录日志；
        -- login_log.tenant_id 的 FK（→public.tenants）仅能拦截不存在的租户。
        (COALESCE(NULLIF(payload->>'tenantId', ''), current_logto_tenant_id()), NULL,
         v_user_id, v_username, COALESCE(v_login_type, 'unknown'), 'success',
         v_ip, v_agent, ip2region(v_ip), 'PostSignIn', COALESCE(v_ts, now()));
-- 2026-11-19 修补：移除函数级 EXCEPTION 吞错——本函数唯一的调用方
-- rpc_webhook_logto 在 PostSignIn 分支自行捕获并置 degraded（容错在调用方维护）；
-- 若此处再吞错，v_failed 永不置位、degraded 恒为假，回放校验形同虚设
END;
$$;
REVOKE EXECUTE ON FUNCTION sync_login_log_write(jsonb) FROM PUBLIC;
