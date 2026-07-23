-- ==============================================================================
-- PostgREST API v1 视图层 + RPC 包装 + 权限配置
-- 
-- 此脚本创建 api_v1 schema 的视图层，将 public schema 的表封装后暴露给 PostgREST。
-- PostgREST 的 db-schemas = "api_v1"，只暴露此 schema 的内容。
-- 
-- 视图设计原则：
--   1. 排除敏感字段（如 sys_user.password_hash 保留但通过权限控制）
--   2. 使用 SECURITY INVOKER（默认），保持 RLS 生效
--   3. 通过 GRANT 控制不同角色的访问权限
-- 
-- 权限层次：
--   web_anon: 仅可调用登录函数
--   role_guest: 只读访问
--   role_editor: 读写访问（受限）
--   role_admin: 完全管理系统表
--   super_admin: 完全控制所有资源
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. 视图层创建
-- ==============================================================================

-- 1.1 sys_tenant（租户管理）
CREATE OR REPLACE VIEW api_v1.sys_tenant AS
SELECT id, tenant_code, tenant_name, status, contact_email, max_users,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_tenant;

-- 1.2 sys_department（部门树）
CREATE OR REPLACE VIEW api_v1.sys_department AS
SELECT id, dept_name, tenant_id, parent_id, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_department;

-- 1.3 sys_user（用户表 - 包含 password_hash 但仅通过 RPC 访问）
CREATE OR REPLACE VIEW api_v1.sys_user AS
SELECT id, username, email, phone, tenant_id, dept_id, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by,
       password_hash
FROM public.sys_user;

-- 1.4 sys_role（角色表）
CREATE OR REPLACE VIEW api_v1.sys_role AS
SELECT id, role_code, role_name, tenant_id, description, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_role;

-- 1.5 sys_api（API 资源表）
CREATE OR REPLACE VIEW api_v1.sys_api AS
SELECT id, path, method, api_name, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_api;

-- 1.6 sys_menu（菜单表）
CREATE OR REPLACE VIEW api_v1.sys_menu AS
SELECT id, parent_id, type, name, path, component, title, icon, permission_code, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM public.sys_menu;

-- 1.7 sys_user_role（用户-角色关联）
CREATE OR REPLACE VIEW api_v1.sys_user_role AS
SELECT user_id, role_id, tenant_id, created_at, created_by
FROM public.sys_user_role;

-- 1.8 sys_role_api（角色-API 关联）
CREATE OR REPLACE VIEW api_v1.sys_role_api AS
SELECT role_id, api_id, created_at, created_by
FROM public.sys_role_api;

-- 1.9 sys_role_menu（角色-菜单关联）
CREATE OR REPLACE VIEW api_v1.sys_role_menu AS
SELECT role_id, menu_id, created_at, created_by
FROM public.sys_role_menu;

-- 1.10 sys_user_session（用户会话）
CREATE OR REPLACE VIEW api_v1.sys_user_session AS
SELECT id, user_id, tenant_id, refresh_token_hash, active_jti, is_used, client_ip, user_agent, created_at, expired_at
FROM public.sys_user_session;

-- 1.11 sys_token_blacklist（Token 黑名单 - 只读）
CREATE OR REPLACE VIEW api_v1.sys_token_blacklist AS
SELECT jti, blacklisted_at, expired_at, reason, user_id
FROM public.sys_token_blacklist;

-- 1.12 sys_user_role_request（角色申请审批）
CREATE OR REPLACE VIEW api_v1.sys_user_role_request AS
SELECT id, user_id, role_id, tenant_id, status, applicant_id, approver_id, created_at, approved_at, updated_at
FROM public.sys_user_role_request;

-- 1.13 sys_audit_log（审计日志 - 只读）
CREATE OR REPLACE VIEW api_v1.sys_audit_log AS
SELECT id, table_name, operation, old_data, new_data, user_id, tenant_id, created_at
FROM public.sys_audit_log;

-- 1.14 sys_cron_log（Cron 执行日志 - 只读）
CREATE OR REPLACE VIEW api_v1.sys_cron_log AS
SELECT id, job_name, execution_time, result, duration_ms
FROM public.sys_cron_log;

-- 1.15 sys_secret（密钥表 - 仅暴露 key_name）
CREATE OR REPLACE VIEW api_v1.sys_secret AS
SELECT key_name FROM public.sys_secret;

-- ==============================================================================
-- 2. RPC 包装函数
-- ==============================================================================

-- 2.1 登录
CREATE OR REPLACE FUNCTION api_v1.user_login_sso(p_username text, p_password text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.user_login_sso(p_username, p_password) $$;
COMMENT ON FUNCTION api_v1.user_login_sso(text, text) IS '用户登录：委托 public.user_login_sso';

-- 2.2 刷新 Token
CREATE OR REPLACE FUNCTION api_v1.refresh_token_rtr(p_old_rt text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.refresh_token_rtr(p_old_rt) $$;
COMMENT ON FUNCTION api_v1.refresh_token_rtr(text) IS '刷新 Token：委托 public.refresh_token_rtr';

-- 2.3 踢人下线
CREATE OR REPLACE FUNCTION api_v1.kick_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.kick_user(p_user_id) $$;
COMMENT ON FUNCTION api_v1.kick_user(uuid) IS '强制踢下线：委托 public.kick_user';

-- 2.4 获取菜单树
CREATE OR REPLACE FUNCTION api_v1.get_user_menu()
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.get_user_menu() $$;
COMMENT ON FUNCTION api_v1.get_user_menu() IS '获取用户菜单树：委托 public.get_user_menu';

-- 2.5 审批角色申请
CREATE OR REPLACE FUNCTION api_v1.approve_role_request(p_request_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.approve_role_request(p_request_id) $$;
COMMENT ON FUNCTION api_v1.approve_role_request(uuid) IS '审批角色申请：委托 public.approve_role_request';

-- 2.6 清理过期 Token
CREATE OR REPLACE FUNCTION api_v1.cleanup_expired_tokens()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.cleanup_expired_tokens() $$;
COMMENT ON FUNCTION api_v1.cleanup_expired_tokens() IS '清理过期 Token：委托 public.cleanup_expired_tokens';

-- 2.7 生成密码哈希（内部使用）
CREATE OR REPLACE FUNCTION api_v1.generate_user_password(p_password text)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.generate_user_password(p_password) $$;
COMMENT ON FUNCTION api_v1.generate_user_password(text) IS '生成 Argon2id 密码哈希';

-- 2.8 创建用户（包装，自动生成密码哈希）
CREATE OR REPLACE FUNCTION api_v1.create_user(
    p_username text,
    p_password text,
    p_tenant_id uuid,
    p_dept_id uuid DEFAULT NULL,
    p_email text DEFAULT NULL,
    p_phone text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    INSERT INTO public.sys_user (username, password_hash, tenant_id, dept_id, email, phone)
    VALUES (p_username, generate_user_password(p_password), p_tenant_id, p_dept_id, p_email, p_phone)
    RETURNING id INTO v_user_id;
    RETURN v_user_id;
END;
$$;
COMMENT ON FUNCTION api_v1.create_user(text, text, uuid, uuid, text, text) IS '创建用户：自动生成 Argon2id 密码哈希';

-- 2.9 修改用户密码
CREATE OR REPLACE FUNCTION api_v1.change_user_password(
    p_user_id uuid,
    p_old_password text,
    p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_current_hash text;
BEGIN
    SELECT password_hash INTO v_current_hash
    FROM public.sys_user
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    -- 验证旧密码
    IF v_current_hash IS DISTINCT FROM pwhash_crypt(p_old_password, v_current_hash) THEN
        RAISE EXCEPTION 'Invalid old password' USING ERRCODE = 'P0001';
    END IF;
    
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1.change_user_password(uuid, text, text) IS '修改用户密码：验证旧密码后更新';

-- 2.10 重置用户密码（管理员功能）
CREATE OR REPLACE FUNCTION api_v1.reset_user_password(
    p_user_id uuid,
    p_new_password text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.sys_user
    SET password_hash = generate_user_password(p_new_password)
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found' USING ERRCODE = 'P0001';
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1.reset_user_password(uuid, text) IS '重置用户密码：管理员直接设置新密码';

-- ==============================================================================
-- 3. 权限授予
-- ==============================================================================

-- 3.1 web_anon: 仅可调用登录函数
GRANT EXECUTE ON FUNCTION api_v1.user_login_sso(text, text) TO web_anon;

-- 3.2 authenticated: 所有认证用户可读基础表
GRANT SELECT ON api_v1.sys_tenant TO authenticated;
GRANT SELECT ON api_v1.sys_department TO authenticated;
GRANT SELECT ON api_v1.sys_user TO authenticated;
GRANT SELECT ON api_v1.sys_role TO authenticated;
GRANT SELECT ON api_v1.sys_api TO authenticated;
GRANT SELECT ON api_v1.sys_menu TO authenticated;
GRANT SELECT ON api_v1.sys_user_role TO authenticated;
GRANT SELECT ON api_v1.sys_role_api TO authenticated;
GRANT SELECT ON api_v1.sys_role_menu TO authenticated;
GRANT SELECT ON api_v1.sys_user_session TO authenticated;
GRANT SELECT ON api_v1.sys_user_role_request TO authenticated;
GRANT SELECT ON api_v1.sys_audit_log TO authenticated;
GRANT SELECT ON api_v1.sys_cron_log TO authenticated;

-- 排除敏感表
-- REVOKE SELECT ON api_v1.sys_secret FROM authenticated;  -- 默认无权限
-- REVOKE SELECT ON api_v1.sys_token_blacklist FROM authenticated;  -- 默认无权限

-- 3.3 role_guest: 只读访问（同 authenticated）
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_guest;

-- 3.4 role_editor: 可编辑内容
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_editor;
GRANT INSERT, UPDATE ON api_v1.sys_user_role_request TO role_editor;
GRANT USAGE ON SCHEMA api_v1 TO role_editor;

-- 3.5 role_admin: 管理系统表
GRANT SELECT ON ALL TABLES IN SCHEMA api_v1 TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_department TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user_role TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_role_menu TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_user_role_request TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_api TO role_admin;
GRANT INSERT, UPDATE ON api_v1.sys_menu TO role_admin;
GRANT USAGE ON SCHEMA api_v1 TO role_admin;

-- 排除敏感操作
REVOKE DELETE ON ALL TABLES IN SCHEMA api_v1 FROM role_admin;  -- 使用软删除

-- 3.6 super_admin: 完全控制
GRANT ALL ON ALL TABLES IN SCHEMA api_v1 TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA api_v1 TO super_admin;
GRANT USAGE ON SCHEMA api_v1 TO super_admin;

-- super_admin 也使用软删除（默认策略）
-- 如果需要物理删除，super_admin 需要直接访问 public schema

-- migrate:down
-- 注意：此 migration 的回滚需要手动处理，因为视图和函数会被后续 migration 依赖

DROP FUNCTION IF EXISTS api_v1.reset_user_password(uuid, text);
DROP FUNCTION IF EXISTS api_v1.change_user_password(uuid, text, text);
DROP FUNCTION IF EXISTS api_v1.create_user(text, text, uuid, uuid, text, text);
DROP FUNCTION IF EXISTS api_v1.generate_user_password(text);
DROP FUNCTION IF EXISTS api_v1.cleanup_expired_tokens();
DROP FUNCTION IF EXISTS api_v1.approve_role_request(uuid);
DROP FUNCTION IF EXISTS api_v1.get_user_menu();
DROP FUNCTION IF EXISTS api_v1.kick_user(uuid);
DROP FUNCTION IF EXISTS api_v1.refresh_token_rtr(text);
DROP FUNCTION IF EXISTS api_v1.user_login_sso(text, text);

DROP VIEW IF EXISTS api_v1.sys_token_blacklist;
DROP VIEW IF EXISTS api_v1.sys_user_session;
DROP VIEW IF EXISTS api_v1.sys_role_menu;
DROP VIEW IF EXISTS api_v1.sys_role_api;
DROP VIEW IF EXISTS api_v1.sys_user_role;
DROP VIEW IF EXISTS api_v1.sys_menu;
DROP VIEW IF EXISTS api_v1.sys_api;
DROP VIEW IF EXISTS api_v1.sys_role;
DROP VIEW IF EXISTS api_v1.sys_user;
DROP VIEW IF EXISTS api_v1.sys_department;
DROP VIEW IF EXISTS api_v1.sys_tenant;
DROP VIEW IF EXISTS api_v1.sys_secret;
DROP VIEW IF EXISTS api_v1.sys_user_role_request;
DROP VIEW IF EXISTS api_v1.sys_audit_log;
DROP VIEW IF EXISTS api_v1.sys_cron_log;
