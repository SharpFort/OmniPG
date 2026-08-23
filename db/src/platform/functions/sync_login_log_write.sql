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

    SELECT key INTO v_login_type
    FROM jsonb_each_text(COALESCE(payload->'user'->'identities', '{}'::jsonb))
    LIMIT 1;

    INSERT INTO login_log
        (tenant_id, organization_id, user_id, username, login_type, result, ip, user_agent,
         region, logto_event, created_at)
    VALUES
        (current_logto_tenant_id(), NULL, v_user_id, v_username, COALESCE(v_login_type, 'unknown'), 'success',
         v_ip, v_agent, ip2region(v_ip), 'PostSignIn', COALESCE(v_ts, now()));
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;
REVOKE EXECUTE ON FUNCTION sync_login_log_write(jsonb) FROM PUBLIC;
