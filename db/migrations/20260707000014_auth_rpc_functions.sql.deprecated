-- ==============================================================================
-- Migration 014: Phase 2 — 认证 RPC 接口增强
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. logout：当前用户登出（将当前 JTI 加入黑名单）
-- ==============================================================================
CREATE OR REPLACE FUNCTION api_v1.logout()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_jti varchar;
    v_user_id uuid;
    v_exp integer;
BEGIN
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    IF v_jti IS NULL THEN
        RAISE EXCEPTION 'No token found' USING ERRCODE = 'P0001';
    END IF;
    
    -- 从 JWT 中提取 exp
    v_exp := (current_setting('request.jwt.claims', true)::json->>'exp')::integer;
    
    INSERT INTO public.sys_token_blacklist (jti, expired_at, reason, user_id)
    VALUES (v_jti, to_timestamp(v_exp), 'logout', v_user_id)
    ON CONFLICT (jti) DO NOTHING;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1.logout() IS '用户登出：将当前 JWT 的 jti 加入黑名单';
GRANT EXECUTE ON FUNCTION api_v1.logout() TO authenticated;

-- ==============================================================================
-- 2. get_current_user：获取当前登录用户信息
-- ==============================================================================
CREATE OR REPLACE FUNCTION api_v1.get_current_user()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_user RECORD;
BEGIN
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    
    IF v_user_id IS NULL OR v_user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;
    
    SELECT u.id, u.username, u.email, u.phone, u.tenant_id, u.dept_id, u.is_active,
           u.created_at, u.updated_at,
           t.tenant_name, t.tenant_code,
           d.dept_name,
           (current_setting('request.jwt.claims', true)::json->'roles')::jsonb AS roles
    INTO v_user
    FROM public.sys_user u
    LEFT JOIN public.sys_tenant t ON u.tenant_id = t.id
    LEFT JOIN public.sys_department d ON u.dept_id = d.id
    WHERE u.id = v_user_id AND u.deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN json_build_object(
        'id', v_user.id,
        'username', v_user.username,
        'email', v_user.email,
        'phone', v_user.phone,
        'tenant_id', v_user.tenant_id,
        'tenant_name', v_user.tenant_name,
        'tenant_code', v_user.tenant_code,
        'dept_id', v_user.dept_id,
        'dept_name', v_user.dept_name,
        'is_active', v_user.is_active,
        'roles', v_user.roles,
        'created_at', v_user.created_at,
        'updated_at', v_user.updated_at
    );
END;
$$;
COMMENT ON FUNCTION api_v1.get_current_user() IS '获取当前登录用户信息（从 JWT claims 提取）';
GRANT EXECUTE ON FUNCTION api_v1.get_current_user() TO authenticated;

-- ==============================================================================
-- 3. get_user_permissions：获取当前用户的 API 权限列表
-- ==============================================================================
CREATE OR REPLACE FUNCTION api_v1.get_user_permissions()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_roles jsonb;
    v_permissions jsonb;
BEGIN
    v_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    v_roles := (current_setting('request.jwt.claims', true)::json->'roles')::jsonb;
    
    IF v_user_id IS NULL OR v_user_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;
    
    -- 从 casbin_rule 视图获取该用户所有角色的 API 权限
    SELECT COALESCE(json_agg(
        json_build_object('path', v1, 'method', v2) ORDER BY v1, v2
    ), '[]'::json) INTO v_permissions
    FROM public.casbin_rule
    WHERE v0 IN (SELECT jsonb_array_elements_text(v_roles));
    
    RETURN json_build_object(
        'user_id', v_user_id::text,
        'roles', v_roles,
        'permissions', v_permissions
    );
END;
$$;
COMMENT ON FUNCTION api_v1.get_user_permissions() IS '获取当前用户的 API 权限列表（基于 Casbin 策略）';
GRANT EXECUTE ON FUNCTION api_v1.get_user_permissions() TO authenticated;

-- ==============================================================================
-- 4. 补充：Heartbeat / Health Check
-- ==============================================================================
CREATE OR REPLACE FUNCTION api_v1.health_check()
RETURNS json
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    SELECT json_build_object(
        'status', 'ok',
        'timestamp', now(),
        'database', current_database(),
        'version', current_setting('server_version')
    );
$$;
COMMENT ON FUNCTION api_v1.health_check() IS '健康检查接口（无认证要求，PostgREST 匿名访问也可用）';
GRANT EXECUTE ON FUNCTION api_v1.health_check() TO web_anon;

-- migrate:down
DROP FUNCTION IF EXISTS api_v1.health_check();
DROP FUNCTION IF EXISTS api_v1.get_user_permissions();
DROP FUNCTION IF EXISTS api_v1.get_current_user();
DROP FUNCTION IF EXISTS api_v1.logout();
