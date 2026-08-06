-- ==============================================================================
-- 初始 Schema 和角色创建（容器首次启动自动执行）
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS api_v1;
COMMENT ON SCHEMA api_v1 IS 'PostgREST 暴露的业务 API Schema';

-- 系统管理 API Schema（027 改名链兼容）
--   api_v1_sys  : 历史迁移引用承载（027 迁移 RENAME → api_v1_public 或清理残留）
--   api_v1_public: 系统管理 API 暴露层（027 定稿名；视图名 = 底层表名）
CREATE SCHEMA IF NOT EXISTS api_v1_sys;
COMMENT ON SCHEMA api_v1_sys IS '系统管理 API Schema（兼容历史迁移引用；027 迁移统一收敛）';
CREATE SCHEMA IF NOT EXISTS api_v1_public;
COMMENT ON SCHEMA api_v1_public IS '系统管理 API 暴露层（027 定稿：视图名=底层表名；原 api_v1_sys）';

CREATE SCHEMA IF NOT EXISTS net;
COMMENT ON SCHEMA net IS 'pg_net 异步 HTTP 请求 Schema';

-- ==============================================================================
-- 角色创建
-- ==============================================================================

-- 1. 匿名角色（无权访问数据）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- 2. 认证用户角色
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- 3. authenticator 角色（PostgREST 连接用的 LOGIN 角色）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'authenticator_dev_pass';
    END IF;
END
$$;

-- 4. （T7 移除）casdoor 角色已退役——Logto 直连 PG 5433，无 casdoor DB/角色

-- 业务角色（JWT roles 数组映射到 PG 角色，与 role.role_code 一致）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'super_admin') THEN
        CREATE ROLE super_admin NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_admin') THEN
        CREATE ROLE role_admin NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_editor') THEN
        CREATE ROLE role_editor NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_guest') THEN
        CREATE ROLE role_guest NOLOGIN NOINHERIT;
    END IF;
END
$$;

-- 将业务角色授予 authenticator（允许 SET ROLE 切换）
GRANT super_admin TO authenticator;
GRANT role_admin TO authenticator;
GRANT role_editor TO authenticator;
GRANT role_guest TO authenticator;

-- ==============================================================================
-- 角色权限授予
-- ==============================================================================

-- authenticator 可以切换到 web_anon 和 authenticated
GRANT web_anon TO authenticator;
GRANT authenticated TO authenticator;

-- Schema 使用权
GRANT USAGE ON SCHEMA api_v1 TO web_anon;
GRANT USAGE ON SCHEMA api_v1 TO authenticated;
GRANT USAGE ON SCHEMA api_v1 TO authenticator;

-- web_anon 默认无任何表权限（安全第一）
-- authenticated 的权限在后续 migration 中根据表逐步授予

-- pg_net 权限
GRANT USAGE ON SCHEMA net TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA net TO authenticated;

\echo 'Schema 和角色创建完成'

-- ==============================================================================
-- T7: 原 api_v1.check_token_blacklist 包装函数（PGRST_DB_PRE_REQUEST）已退役
--     D12: 会话/吊销交 Logto；PGRST_DB_PRE_REQUEST 已清空
-- ==============================================================================

