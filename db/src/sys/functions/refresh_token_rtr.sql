-- db/src/sys/functions/refresh_token_rtr.sql
-- Refresh Token 轮转刷新（含防重放攻击）
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION refresh_token_rtr(p_old_rt text)
RETURNS json AS $$
DECLARE
    v_old_rt_hash varchar;
    v_session RECORD;
    v_user RECORD;
    v_roles_json jsonb;
    v_jti varchar;
    v_new_rt varchar;
    v_new_rt_hash varchar;
    v_payload jsonb;
    v_new_at varchar;
    v_cookie_header text;
BEGIN
    -- 1. 计算旧 RT 的哈希
    v_old_rt_hash := sha256(p_old_rt::bytea);

    -- 2. 查找会话
    SELECT s.id, s.user_id, s.is_used, s.active_jti, s.expired_at, s.tenant_id
    INTO v_session
    FROM sys_user_session s
    WHERE s.refresh_token_hash = v_old_rt_hash;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Refresh Token' USING ERRCODE = 'P0001';
    END IF;

    -- 3. RTR 防重放：如果旧 RT 已被使用，则发生盗用，全端下线
    IF v_session.is_used = TRUE THEN
        PERFORM kick_user(v_session.user_id);
        RAISE EXCEPTION 'Refresh Token Reuse Detected' USING ERRCODE = 'P0004';
    END IF;

    -- 4. 检查是否过期
    IF v_session.expired_at < NOW() THEN
        RAISE EXCEPTION 'Refresh Token Expired' USING ERRCODE = 'P0001';
    END IF;

    -- 5. 查询用户信息
    SELECT id, username, tenant_id, dept_id INTO v_user
    FROM sys_user WHERE id = v_session.user_id;

    -- 6. 获取最新角色（包括全局角色 + 本租户角色）
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id
      AND r.deleted_at IS NULL
      AND (r.tenant_id IS NULL OR r.tenant_id = v_user.tenant_id);
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 7. 作废旧 RT
    UPDATE sys_user_session SET is_used = TRUE WHERE id = v_session.id;

    -- 8. 生成新会话
    v_jti := uuidv7()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, tenant_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_user.id, v_user.tenant_id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 9. 构造新 JWT Payload（含最新角色）
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_user.id::text,
        'username', v_user.username,
        'tenant_id', v_user.tenant_id::text,
        'dept_id', COALESCE(v_user.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    -- 10. 调用 Casdoor 签发新 AT
    DECLARE
        v_response http_response;
        v_casdoor_url text;
    BEGIN
        SELECT key_value INTO v_casdoor_url FROM sys_secret WHERE key_name = 'casdoor_jwks_url';
        IF v_casdoor_url IS NULL THEN
            RAISE EXCEPTION 'Casdoor URL not configured' USING ERRCODE = 'P0098';
        END IF;
        
        v_response := http_post(
            v_casdoor_url || '/api/login/oauth/access_token',
            'username=' || v_user.username || '&grant_type=refresh_token&scope=read',
            'application/x-www-form-urlencoded'
        );
        
        IF v_response.status_code != 200 THEN
            RAISE EXCEPTION 'Casdoor 认证失败，无法刷新 Token' USING ERRCODE = 'P0098';
        END IF;
        
        v_new_at := v_response.content::json->>'access_token';
    END;

    -- 11. 注入新 RT Cookie
    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; SameSite=Strict; Max-Age=604800"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

    -- 12. 返回新 AT
    RETURN json_build_object(
        'access_token', v_new_at,
        'username', v_user.username
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION refresh_token_rtr(text) IS 'Refresh Token 轮转刷新：作废旧 RT → 查最新角色 → Casdoor 签发新双 Token → 防重放攻击';
