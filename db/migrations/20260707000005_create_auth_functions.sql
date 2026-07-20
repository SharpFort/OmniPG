-- ==============================================================================
-- Migration 005: 认证函数（登录/刷新/黑名单检查/踢人）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 0. 辅助函数：sha256 包装（JWT 签发已委托 Casdoor）
-- ==============================================================================

-- sha256 包装：封装 pgcrypto 的 digest() 为易用的 sha256()
CREATE OR REPLACE FUNCTION sha256(data bytea) 
RETURNS text AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;
COMMENT ON FUNCTION sha256(bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值';

-- ==============================================================================
-- [修复 P0-1] JWT 签发已委托 Casdoor，不再使用 plpython3u 内签
-- 2026-07-10：移除 generate_rs256_jwt，所有 JWT 由 Casdoor RS256 签发
-- ==============================================================================

-- ==============================================================================
-- 1. check_token_blacklist：PostgREST db-pre-request 函数
-- ==============================================================================
CREATE OR REPLACE FUNCTION check_token_blacklist()
RETURNS void AS $$
DECLARE
    v_jti varchar;
BEGIN
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    -- [修复 P1-3] 仅拦截未过期的黑名单 jti
    IF v_jti IS DISTINCT FROM NULL AND EXISTS (
        SELECT 1 FROM sys_token_blacklist WHERE jti = v_jti AND expired_at > now()
    ) THEN
        RAISE EXCEPTION 'Token Has Been Revoked' USING ERRCODE = 'P0001';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION check_token_blacklist() IS 'db-pre-request 拦截函数：检测 JWT 的 jti 是否在黑名单中';

-- ==============================================================================
-- 2. user_login_sso：登录并签发双 Token
-- ==============================================================================
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
    WHERE username = p_username;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Credentials' USING ERRCODE = 'P0001';
    END IF;

    -- 2. 检查账户是否激活
    IF v_user.is_active = FALSE THEN
        RAISE EXCEPTION 'Account Disabled' USING ERRCODE = 'P0002';
    END IF;

    -- 3. 验证密码
    IF v_user.password_hash != crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'Invalid Credentials' USING ERRCODE = 'P0001';
    END IF;

    -- 4. 查询用户角色
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id;

    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 5. 使该用户的旧 RT 全部失效（SSO 单设备登录）
    UPDATE sys_user_session SET is_used = TRUE 
    WHERE user_id = v_user.id AND is_used = FALSE;

    -- 6. 生成新会话
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_user.id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 7. 构造 JWT Payload
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_user.id::text,
        'username', v_user.username,
        'tenant_id', v_user.tenant_id,
        'dept_id', COALESCE(v_user.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    -- 8. [修复 P0-1] 调用 Casdoor 获取 JWT
    DECLARE
        v_response http_response;
        v_casdoor_url text := 'http://casdoor:8000';
    BEGIN
        SELECT key_value INTO v_casdoor_url FROM sys_secret WHERE key_name = 'casdoor_jwks_url';
        
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

    -- 9. 注入 httpOnly Cookie（PostgREST 通过 response.headers 发送）
    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; SameSite=Strict; Max-Age=604800  -- Secure 由反向代理层控制"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

    -- 10. 返回 Access Token + 用户信息（不含 RT）
    RETURN json_build_object(
        'access_token', v_new_at,
        'username', v_user.username
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION user_login_sso(text, text) IS '用户登录：RS256 签名 JWT，SSO 单设备登录，httpOnly Cookie 写入 Refresh Token';

-- ==============================================================================
-- 3. refresh_token_rtr：双 Token 轮转刷新（含防重放攻击）
-- ==============================================================================
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
    SELECT s.id, s.user_id, s.is_used, s.active_jti, s.expired_at
    INTO v_session
    FROM sys_user_session s
    WHERE s.refresh_token_hash = v_old_rt_hash;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Refresh Token' USING ERRCODE = 'P0001';
    END IF;

    -- 3. 检查是否已使用（防重放）
    IF v_session.is_used = TRUE THEN
        -- 检测到重放攻击，踢出该用户所有会话
        PERFORM kick_user(v_session.user_id);
        RAISE EXCEPTION 'Refresh Token Reuse Detected' USING ERRCODE = 'P0004';
    END IF;

    -- 4. 检查是否过期
    IF v_session.expired_at < now() THEN
        RAISE EXCEPTION 'Refresh Token Expired' USING ERRCODE = 'P0001';
    END IF;

    -- 5. 将旧 RT 标记为已使用
    UPDATE sys_user_session SET is_used = TRUE WHERE id = v_session.id;

    -- 6. 查询用户最新角色
    SELECT id, username, tenant_id, dept_id INTO v_user
    FROM sys_user WHERE id = v_session.user_id;

    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id;
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 7. 生成新会话
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_session.user_id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 8. 构造新 JWT Payload（含最新角色）
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_session.user_id::text,
        'username', v_user.username,
        'tenant_id', v_user.tenant_id,
        'dept_id', COALESCE(v_user.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    -- 9. [修复 P0-1] 签发新 AT — 调用 Casdoor
    DECLARE
        v_response http_response;
        v_casdoor_url text := 'http://casdoor:8000';
    BEGIN
        SELECT key_value INTO v_casdoor_url FROM sys_secret WHERE key_name = 'casdoor_jwks_url';
        
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

    -- 10. 注入新 RT Cookie
    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; SameSite=Strict; Max-Age=604800  -- Secure 由反向代理层控制"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

    -- 11. 返回新 AT
    RETURN json_build_object(
        'access_token', v_new_at,
        'username', v_user.username
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION refresh_token_rtr(text) IS 'Refresh Token 轮转刷新：作废旧 RT → 查最新角色 → 签发新双 Token → 防重放攻击';

-- ==============================================================================
-- 4. kick_user：管理员强制踢下线
-- ==============================================================================
CREATE OR REPLACE FUNCTION kick_user(p_user_id uuid)
RETURNS boolean AS $$
DECLARE
    v_session RECORD;
BEGIN
    -- 将该用户所有活跃会话的 AT jti 加入黑名单
    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = p_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at, reason)
        VALUES (v_session.active_jti, v_session.expired_at, 'kicked')
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    -- 标记所有活跃 RT 已使用
    UPDATE sys_user_session SET is_used = TRUE WHERE user_id = p_user_id AND is_used = FALSE;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION kick_user(uuid) IS '强制踢下线：将该用户所有活跃会话的 Access Token 加入黑名单';

-- migrate:down

DROP FUNCTION IF EXISTS kick_user(uuid);
DROP FUNCTION IF EXISTS refresh_token_rtr(text);
DROP FUNCTION IF EXISTS user_login_sso(text, text);
DROP FUNCTION IF EXISTS check_token_blacklist();
DROP FUNCTION IF EXISTS sha256(bytea);
