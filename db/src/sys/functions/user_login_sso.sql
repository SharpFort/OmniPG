-- db/src/sys/functions/user_login_sso.sql
-- SSO 登录函数：Argon2id 验证密码，Casdoor RS256 签发 JWT
-- 使用 pg_pwhash (Argon2id) 验证密码
-- JWT 签发委托 Casdoor（已有完整 Casdoor 集成）
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION user_login_sso(p_username text, p_password text)
RETURNS json AS $$
DECLARE
    v_user RECORD;
    v_roles_json jsonb;
    v_jti varchar;
    v_new_rt varchar;
    v_new_rt_hash varchar;
    v_payload jsonb;
    v_new_at varchar;
    v_cookie_header text;
BEGIN
    -- 1. 查询用户
    SELECT id, username, password_hash, tenant_id, dept_id, is_active
    INTO v_user
    FROM sys_user
    WHERE username = p_username AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Credentials' USING ERRCODE = 'P0001';
    END IF;

    -- 2. 检查账户是否激活
    IF v_user.is_active = FALSE THEN
        RAISE EXCEPTION 'Account Disabled' USING ERRCODE = 'P0002';
    END IF;

    -- 3. 使用 pg_pwhash (Argon2id) 验证密码
    IF v_user.password_hash IS DISTINCT FROM pwhash_crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'Invalid Credentials' USING ERRCODE = 'P0001';
    END IF;

    -- 4. 聚合该用户的所有角色代码（包括全局角色 + 本租户角色）
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id
      AND r.deleted_at IS NULL
      AND (r.tenant_id IS NULL OR r.tenant_id = v_user.tenant_id);

    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 5. SSO：作废该用户旧的活跃会话
    UPDATE sys_user_session SET is_used = TRUE 
    WHERE user_id = v_user.id AND is_used = FALSE;

    -- 6. 生成新会话
    v_jti := uuidv7()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, tenant_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_user.id, v_user.tenant_id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 7. 构造 JWT Payload（用于 Casdoor 参考/日志记录）
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_user.id::text,
        'username', v_user.username,
        'tenant_id', v_user.tenant_id::text,
        'dept_id', COALESCE(v_user.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    -- 8. 调用 Casdoor 获取 JWT
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
            'username=' || p_username || '&password=' || p_password || '&scope=read',
            'application/x-www-form-urlencoded'
        );
        
        IF v_response.status_code != 200 THEN
            RAISE EXCEPTION 'Casdoor 认证失败' USING ERRCODE = 'P0098';
        END IF;
        
        v_new_at := v_response.content::json->>'access_token';
        IF v_new_at IS NULL THEN
            RAISE EXCEPTION 'Casdoor 返回空 token' USING ERRCODE = 'P0098';
        END IF;
    END;

    -- 9. 注入 httpOnly Cookie
    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; SameSite=Strict; Max-Age=604800"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

    -- 10. 返回 Access Token + 用户信息
    RETURN json_build_object(
        'access_token', v_new_at,
        'username', v_user.username
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION user_login_sso(text, text) IS '用户登录：Argon2id 验证密码，Casdoor RS256 签发 JWT，SSO 单设备登录，httpOnly Cookie 写入 Refresh Token';
