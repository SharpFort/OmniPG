# 07 — 数据库 Migration 与种子数据

> **定位：** 提供完整的 Dbmate migration 文件（9个 up + 9个 down）和 1 个种子数据文件。Agent 按文件编号顺序执行即可部署完整数据库。
> **前置依赖：** 01-环境搭建（PG 就绪、扩展已启用、Schema/角色已创建）
> **执行工具：** Dbmate（`dbmate up`）或直接 `psql -f`
> **产出物：** 11 张业务表 + 1 个视图 + 6 个函数 + 3 个触发器 + RLS 策略 + 种子数据
> **预计耗时：** 30-60 分钟（取决于是否重新生成 RSA 密钥）

---

## 1. 快速开始

### 1.1 前置条件

```powershell
# 1. 检查 Dbmate 是否安装
dbmate --version

# 2. 如果未安装，下载 Dbmate（Windows）
winget install dbmate
# 或
scoop install dbmate

# 3. 设置环境变量
$env:DBMATE_DATABASE_URL = "postgres://app_owner:***@localhost:5433/app_db?sslmode=disable"
```

### 1.2 一键部署

```powershell
# 进入 db 目录
cd "D:\WeChat Files\xiangmu\源码\db"

# 上传所有 migration
dbmate up

# 查看状态
dbmate status

# 加载种子数据
dbmate up:seed
```

---

## 2. Migration 文件清单

```
db/
├── .dbmate.toml              # Dbmate 配置文件
├── migrations/               # Migration 文件目录
│   ├── 20260707000001_init_tables.sql
│   ├── 20260707000002_create_relation_sessions_blacklist.sql
│   ├── 20260707000003_create_casbin_view.sql
│   ├── 20260707000004_create_notify_triggers.sql
│   ├── 20260707000005_create_auth_functions.sql
│   ├── 20260707000006_create_permission_functions.sql
│   ├── 20260707000007_create_security_triggers.sql
│   ├── 20260707000008_enable_rls_policies.sql
│   └── 20260707000009_seed_data.sql
└── tests/                    # pgTAP 测试（可选）
    └── test_basic.sql
```

---

## 3. Dbmate 配置文件

**文件：** `db/.dbmate.toml`

```toml
# Dbmate 配置文件
# 文档：https://github.com/amacneil/dbmate

# 数据库连接 URL（通过环境变量读取，支持多环境）
database_url = "${DBMATE_DATABASE_URL}"

# Migration 文件目录
migrations_dir = "./migrations"

# 迁移表名（默认 schema_migrations）
migration_table = "schema_migrations"

# 是否自动创建迁移表（默认 true）
auto_migration_table = true

# 迁移文件命名格式
id_format = "20060102150405"
```

---

## 4. Migration 001：基础表

**文件：** `db/migrations/20260707000001_init_tables.sql`

```sql
-- ==============================================================================
-- Migration 001: 创建基础表（6 张表）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. 密钥配置表（仅 SECURITY DEFINER 函数可读）
-- ==============================================================================
CREATE TABLE sys_secret (
    key_name VARCHAR(100) PRIMARY KEY,
    key_value TEXT NOT NULL
);
COMMENT ON TABLE sys_secret IS '系统密钥存储表，存放 JWT 私钥等敏感配置';
COMMENT ON COLUMN sys_secret.key_name IS '密钥名称';
COMMENT ON COLUMN sys_secret.key_value IS '密钥值（PEM 格式）';

-- ==============================================================================
-- 2. 部门表（支持树形结构）
-- ==============================================================================
CREATE TABLE sys_department (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dept_name VARCHAR(100) NOT NULL,
    parent_id UUID REFERENCES sys_department(id) ON DELETE RESTRICT,  -- [修复 P2-4] 有子部门时禁止删除
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_department IS '部门组织架构表';
COMMENT ON COLUMN sys_department.parent_id IS '上级部门 ID，NULL 表示根部门';
CREATE INDEX idx_department_parent ON sys_department(parent_id);

-- ==============================================================================
-- 3. 用户表（含多租户 + 部门字段）
-- ==============================================================================
CREATE TABLE sys_user (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    tenant_id VARCHAR(50) NOT NULL,
    dept_id UUID REFERENCES sys_department(id) ON DELETE SET NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_user IS '用户表，支持多租户和部门关联';
COMMENT ON COLUMN sys_user.tenant_id IS '租户标识，用于多租户行级隔离';
COMMENT ON COLUMN sys_user.password_hash IS 'bcrypt 哈希值（cost=10）';
COMMENT ON COLUMN sys_user.is_active IS '账户是否激活（soft delete 标记）';
CREATE INDEX idx_user_tenant_dept ON sys_user(tenant_id, dept_id);
CREATE INDEX idx_user_username ON sys_user(username);
CREATE INDEX idx_user_tenant_active ON sys_user(tenant_id, is_active);

-- ==============================================================================
-- 4. 角色表
-- ==============================================================================
CREATE TABLE sys_role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code VARCHAR(50) NOT NULL UNIQUE,
    role_name VARCHAR(100) NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_role IS '角色表，role_code 写入 JWT 的 roles 数组';
COMMENT ON COLUMN sys_role.role_code IS '角色代码（英文标识），如 super_admin, role_guest';
CREATE INDEX idx_role_code ON sys_role(role_code);

-- ==============================================================================
-- 5. API 资源表（Casbin 防御对象）
-- ==============================================================================
CREATE TABLE sys_api (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    path VARCHAR(255) NOT NULL,
    method VARCHAR(10) NOT NULL,
    api_name VARCHAR(100),
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_api IS 'API 资源表，定义网关层 Casbin 的边界防御规则';
COMMENT ON COLUMN sys_api.path IS 'API 路径模式，如 /sys_user, /rpc/user_login_sso';
COMMENT ON COLUMN sys_api.method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH';
CREATE INDEX idx_api_path_method ON sys_api(path, method);
CREATE UNIQUE INDEX idx_api_path_method_unique ON sys_api(path, method);

-- ==============================================================================
-- 6. 菜单与按钮权限表
-- ==============================================================================
CREATE TABLE sys_menu (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    type VARCHAR(10) NOT NULL CHECK (type IN ('DIR', 'MENU', 'BUTTON')),
    name VARCHAR(100) NOT NULL,
    path VARCHAR(255),
    component VARCHAR(255),
    title VARCHAR(100) NOT NULL,
    icon VARCHAR(100),
    permission_code VARCHAR(100),
    sort_order INT DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_menu IS '菜单与前权限标识表：DIR=目录, MENU=页面菜单, BUTTON=按钮';
COMMENT ON COLUMN sys_menu.component IS '前端组件路径，如 system/user/index';
COMMENT ON COLUMN sys_menu.permission_code IS '按钮权限标识，如 user:add';
CREATE INDEX idx_menu_parent ON sys_menu(parent_id);
CREATE INDEX idx_menu_type ON sys_menu(type);

-- migrate:down

DROP TABLE IF EXISTS sys_menu CASCADE;
DROP TABLE IF EXISTS sys_api CASCADE;
DROP TABLE IF EXISTS sys_role CASCADE;
DROP TABLE IF EXISTS sys_user CASCADE;
DROP TABLE IF EXISTS sys_department CASCADE;
DROP TABLE IF EXISTS sys_secret CASCADE;
```

---

## 5. Migration 002：关联表 + 会话/黑名单表

**文件：** `db/migrations/20260707000002_create_relation_sessions_blacklist.sql`

```sql
-- ==============================================================================
-- Migration 002: 关联表 + 会话/黑名单表
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 7. 用户-角色关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_user_role (
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE,
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE sys_user_role IS '用户-角色关联表';
CREATE INDEX idx_user_role_role ON sys_user_role(role_id);

-- ==============================================================================
-- 8. 角色-API 关联表（Casbin p 规则数据源）
-- ==============================================================================
CREATE TABLE sys_role_api (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    api_id UUID REFERENCES sys_api(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (role_id, api_id)
);
COMMENT ON TABLE sys_role_api IS '角色-API 关联表，casbin_rule 视图的 p 规则数据源';
CREATE INDEX idx_role_api_api ON sys_role_api(api_id);

-- ==============================================================================
-- 9. 角色-菜单关联表
-- ==============================================================================
CREATE TABLE sys_role_menu (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    menu_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (role_id, menu_id)
);
COMMENT ON TABLE sys_role_menu IS '角色-菜单关联表';
CREATE INDEX idx_role_menu_menu ON sys_role_menu(menu_id);

-- ==============================================================================
-- 10. 用户会话表（Refresh Token 管理）
-- ==============================================================================
CREATE TABLE sys_user_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id) ON DELETE CASCADE,
    refresh_token_hash VARCHAR(64) NOT NULL UNIQUE,
    active_jti VARCHAR(50),
    is_used BOOLEAN DEFAULT FALSE,
    client_ip VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL
);
COMMENT ON TABLE sys_user_session IS '用户会话表，管理 Refresh Token 生命周期';
COMMENT ON COLUMN sys_user_session.refresh_token_hash IS 'RT 的 SHA256 哈希（防止泄露）';
COMMENT ON COLUMN sys_user_session.active_jti IS '当前活跃的 AT jti，用于角色变更即时踢下线';
COMMENT ON COLUMN sys_user_session.is_used IS 'RT 是否已被使用（RTR 防重放）';
CREATE INDEX idx_session_user ON sys_user_session(user_id, is_used);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);
CREATE INDEX idx_session_hash ON sys_user_session(refresh_token_hash);

-- ==============================================================================
-- 11. Token 黑名单表
-- ==============================================================================
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY,
    blacklisted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL,
    reason VARCHAR(100)
);
COMMENT ON TABLE sys_token_blacklist IS 'Access Token 黑名单，配合 db-pre-request 实现踢下线';
COMMENT ON COLUMN sys_token_blacklist.reason IS '加入黑名单的原因：role_change, logout, kicked';
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);

-- migrate:down

DROP TABLE IF EXISTS sys_token_blacklist CASCADE;
DROP TABLE IF EXISTS sys_user_session CASCADE;
DROP TABLE IF EXISTS sys_role_menu CASCADE;
DROP TABLE IF EXISTS sys_role_api CASCADE;
DROP TABLE IF EXISTS sys_user_role CASCADE;
```

---

## 6. Migration 003：casbin_rule 视图

**文件：** `db/migrations/20260707000003_create_casbin_view.sql`

```sql
-- ==============================================================================
-- Migration 003: 创建 casbin_rule 视图（Role-in-JWT 优化版，仅 p 规则）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- casbin_rule 视图（Role-in-JWT 策略后，仅保留 p 规则）
-- ==============================================================================
-- [修复 P1-1] casbin_rule 视图添加 is_active 过滤
CREATE OR REPLACE VIEW casbin_rule AS
SELECT 
    NULL::integer AS id,
    'p'::varchar AS ptype,
    r.role_code::varchar AS v0,
    a.path::varchar AS v1,
    a.method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM sys_role_api ra
JOIN sys_role r ON ra.role_id = r.id AND r.is_active = true
JOIN sys_api a ON ra.api_id = a.id AND a.is_active = true;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径模式';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法';

-- migrate:down

DROP VIEW IF EXISTS casbin_rule CASCADE;
```

---

## 7. Migration 004：pg_notify 通知触发器

**文件：** `db/migrations/20260707000004_create_notify_triggers.sql`

```sql
-- ==============================================================================
-- Migration 004: pg_notify 通知触发器（实时同步）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 广播函数：当 sys_role_api 变更时发送 pg_notify
-- ==============================================================================
CREATE OR REPLACE FUNCTION notify_policy_reload()
RETURNS TRIGGER AS $$
BEGIN
    -- [修复 P1-5] pg_notify payload 增强为 JSON
    PERFORM pg_notify('casbin_channel', json_build_object(
        'op', TG_OP,
        'table', TG_TABLE_NAME,
        'ts', extract(epoch from now())::bigint
    )::text);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION notify_policy_reload() IS '发送 casbin_channel 通知，触发 Policy Syncer 实时同步';

-- 绑定触发器到角色-API 关联表
-- FOR EACH STATEMENT 防止批量操作时触发风暴
CREATE TRIGGER trg_reload_on_role_api
AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
FOR EACH STATEMENT EXECUTE FUNCTION notify_policy_reload();

-- migrate:down

DROP TRIGGER IF EXISTS trg_reload_on_role_api ON sys_role_api;
DROP FUNCTION IF EXISTS notify_policy_reload();
```

---

## 8. Migration 005：认证函数

**文件：** `db/migrations/20260707000005_create_auth_functions.sql`

```sql
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
    v_private_key text;
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
        v_roles_json := '[\"role_guest\"]'::jsonb;
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
 '/api/login/oauth/access_token',
 p_username || '&password=' || p_password || '&scope=read',
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
    v_private_key text;
    v_payload jsonb;
    v_new_at varchar;
    v_cookie_header text;
BEGIN
    -- 1. 计算旧 RT 的哈希
 

... [OUTPUT TRUNCATED - 895 chars omitted out of 50895 total] ...

is_us

... [OUTPUT TRUNCATED - 239 chars omitted out of 50239 total] ...

   
    IF v_roles_json IS NULL THEN
        v_roles_json := '[\"role_guest\"]'::jsonb;
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
        'username', v_session.username,
        'tenant_id', v_session.tenant_id,
        'dept_id', COALESCE(v_session.dept_id::text, ''),
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
 '/api/login/oauth/access_token',
 v_session.username || '&scope=read',
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
        'username', v_session.username
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
```

---

## 9. Migration 006：权限管理函数

**文件：** `db/migrations/20260707000006_create_permission_functions.sql`

```sql
-- ==============================================================================
-- Migration 006: 权限管理函数（菜单树/角色审批）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. get_user_menu：获取当前用户的菜单树和按钮权限
-- ==============================================================================
CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json AS $$
DECLARE
    v_username varchar;
    v_user_id uuid;
    v_menu_tree json;
BEGIN
    v_username := current_setting('request.jwt.claims', true)::json->>'username';
    
    IF v_username IS NULL THEN
        RAISE EXCEPTION 'Unauthorized' USING ERRCODE = 'P0001';
    END IF;

    SELECT id INTO v_user_id FROM sys_user WHERE username = v_username;

    -- 递归查询菜单树（仅 DIR 和 MENU 类型）
    WITH RECURSIVE menu_cte AS (
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        WHERE ur.user_id = v_user_id AND m.parent_id IS NULL AND m.type IN ('DIR', 'MENU')
        
        UNION ALL
        
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE ur.user_id = v_user_id AND m.type IN ('DIR', 'MENU')
    )
    SELECT json_agg(row_to_json(t)) INTO v_menu_tree
    FROM (
        SELECT 
            c.id, 
            c.parent_id, 
            c.name, 
            c.path, 
            c.component, 
            json_build_object('title', c.title, 'icon', c.icon) AS meta,
            (
                -- 查询当前菜单下的按钮权限
                SELECT COALESCE(json_agg(btn.permission_code), '[]'::json)
                FROM sys_menu btn
                JOIN sys_role_menu rmb ON btn.id = rmb.menu_id
                JOIN sys_user_role urb ON rmb.role_id = urb.role_id
                WHERE btn.parent_id = c.id 
                  AND btn.type = 'BUTTON' 
                  AND urb.user_id = v_user_id
            ) AS buttons
        FROM menu_cte c
        ORDER BY c.sort_order
    ) t;

    RETURN v_menu_tree;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION get_user_menu() IS '获取当前用户有权访问的菜单树（含按钮权限标识）';

-- ==============================================================================
-- 2. sys_user_role_request：角色分配审批流表
-- ==============================================================================
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    applicant_id UUID NOT NULL,
    approver_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP WITH TIME ZONE,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_user_role_request IS '角色分配审批流表';
CREATE INDEX idx_request_user ON sys_user_role_request(user_id, status);
CREATE INDEX idx_request_status ON sys_user_role_request(status);

-- ==============================================================================
-- 3. approve_role_request：审批角色申请
-- ==============================================================================
CREATE OR REPLACE FUNCTION approve_role_request(p_request_id uuid)
RETURNS boolean AS $$
DECLARE
    v_req RECORD;
    v_approver_id uuid;
BEGIN
    v_approver_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;

    SELECT * INTO v_req FROM sys_user_role_request 
    WHERE id = p_request_id AND status = 'pending' FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found or already processed' USING ERRCODE = 'P0001';
    END IF;

    UPDATE sys_user_role_request 
    SET status = 'approved', approver_id = v_approver_id, approved_at = now(), updated_at = now()
    WHERE id = p_request_id;

    INSERT INTO sys_user_role (user_id, role_id) 
    VALUES (v_req.user_id, v_req.role_id)
    ON CONFLICT DO NOTHING;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION approve_role_request(uuid) IS '审批通过角色申请：在同一事务中更新状态并写入 sys_user_role';

-- migrate:down

DROP FUNCTION IF EXISTS approve_role_request(uuid);
DROP TABLE IF EXISTS sys_user_role_request CASCADE;
DROP FUNCTION IF EXISTS get_user_menu();
```

---

## 10. Migration 007：安全触发器

**文件：** `db/migrations/20260707000007_create_security_triggers.sql`

```sql
-- ==============================================================================
-- Migration 007: 安全触发器（角色变更即时生效）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- [修复 P1-3] updated_at 自动更新触发器
-- ==============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN 
        SELECT table_name FROM information_schema.columns 
        WHERE column_name = 'updated_at' AND table_schema = 'public'
    LOOP
        EXECUTE format('CREATE TRIGGER IF NOT EXISTS trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at()', t, t);
    END LOOP;
END;
$$;

-- ==============================================================================
-- blacklist_at_on_role_change：角色变更时即时使旧 Token 失效
-- ==============================================================================
CREATE OR REPLACE FUNCTION blacklist_at_on_role_change()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_session RECORD;
BEGIN
    -- 确定受影响的用户 ID
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        v_user_id := NEW.user_id;
    ELSE
        v_user_id := OLD.user_id;
    END IF;

    -- 将该用户所有活跃会话的 AT 加入黑名单
    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = v_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at, reason)
        VALUES (v_session.active_jti, v_session.expired_at, 'role_change')
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION blacklist_at_on_role_change() IS '角色变更触发器：将旧 JWT 的 jti 写入黑名单，迫使客户端无感刷新';

-- 绑定触发器到用户-角色关联表
CREATE TRIGGER trg_blacklist_on_role_change
AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
FOR EACH ROW EXECUTE FUNCTION blacklist_at_on_role_change();

-- ==============================================================================
-- [修复 P1-8] Token 清理机制
-- ==============================================================================
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS void AS $$
BEGIN
    DELETE FROM sys_token_blacklist WHERE expired_at < now();
    DELETE FROM sys_user_session WHERE expired_at < now() - interval '1 day';
END;
$$ LANGUAGE plpgsql;

-- migrate:down

DROP FUNCTION IF EXISTS cleanup_expired_tokens();
DROP TRIGGER IF EXISTS trg_blacklist_on_role_change ON sys_user_role;
DROP FUNCTION IF EXISTS blacklist_at_on_role_change();
```

---

## 11. Migration 008：RLS 行级安全策略

**文件：** `db/migrations/20260707000008_enable_rls_policies.sql`

```sql
-- ==============================================================================
-- Migration 008: RLS 行级安全策略
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- RLS 助手函数：高性能读取 JWT 中的上下文
-- ==============================================================================
CREATE OR REPLACE FUNCTION current_user_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'user_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_id() IS '从 JWT 中提取当前用户 ID（STABLE 缓存优化）';

CREATE OR REPLACE FUNCTION current_tenant_id() 
RETURNS varchar AS $$
    SELECT current_setting('request.jwt.claims', true)::json->>'tenant_id';
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_tenant_id() IS '从 JWT 中提取当前租户 ID';

CREATE OR REPLACE FUNCTION current_user_dept_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'dept_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_dept_id() IS '从 JWT 中提取当前部门 ID';

-- ==============================================================================
-- [修复 P0-3] sys_secret 表 RLS — 仅超级管理员可读
-- ==============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

CREATE POLICY secret_no_anonymous ON sys_secret
AS RESTRICTIVE USING (false);

CREATE POLICY secret_read_policy ON sys_secret
FOR SELECT
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

-- ==============================================================================
-- sys_user 表 RLS
-- ==============================================================================
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;

-- 策略 1：租户隔离（RESTRICTIVE，强制所有查询带 tenant_id 过滤）
CREATE POLICY tenant_isolation_strict_policy ON sys_user
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- 策略 2：部门数据隔离（普通员工只看自己部门）
CREATE POLICY employee_dept_isolation_policy ON sys_user
FOR SELECT
USING (
    -- 超级管理员无视 RLS
    current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin'
    -- 同部门可见
    OR dept_id = current_user_dept_id()
    -- 自己可见自己
    OR id = current_user_id()
);

-- ==============================================================================
-- sys_department 表 RLS
-- ==============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

CREATE POLICY dept_tenant_isolation ON sys_department
AS RESTRICTIVE
USING (true);  -- 部门表不按租户隔离

-- ==============================================================================
-- sys_role 表 RLS（仅超级管理员可写）
-- ==============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_read_policy ON sys_role
FOR SELECT
USING (true);  -- 所有认证用户可读

-- ==============================================================================
-- sys_menu 表 RLS
-- ==============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (true);

-- ==============================================================================
-- [修复 P1-2] RLS 扩展到所有 11 张业务表
-- ==============================================================================

ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;
CREATE POLICY api_read_policy ON sys_api FOR SELECT USING (true);
CREATE POLICY api_write_policy ON sys_api FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_role_read_policy ON sys_user_role FOR SELECT USING (true);
CREATE POLICY user_role_write_policy ON sys_user_role FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_role_api ENABLE ROW LEVEL SECURITY;
CREATE POLICY role_api_read_policy ON sys_role_api FOR SELECT USING (true);
CREATE POLICY role_api_write_policy ON sys_role_api FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;
CREATE POLICY session_read_policy ON sys_user_session FOR SELECT
USING (user_id = current_user_id() OR current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');
CREATE POLICY session_write_policy ON sys_user_session FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;
CREATE POLICY blacklist_internal ON sys_token_blacklist AS RESTRICTIVE USING (false);

ALTER TABLE sys_user_role_request ENABLE ROW LEVEL SECURITY;
CREATE POLICY request_read_policy ON sys_user_role_request FOR SELECT
USING (applicant_id = current_user_id() OR current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');
CREATE POLICY request_write_policy ON sys_user_role_request FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY menu_write_policy ON sys_menu FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY dept_write_policy ON sys_department FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

CREATE POLICY role_write_policy ON sys_role FOR ALL
USING (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin')
WITH CHECK (current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin');

-- migrate:down

DROP POLICY IF EXISTS secret_read_policy ON sys_secret;
DROP POLICY IF EXISTS secret_no_anonymous ON sys_secret;
ALTER TABLE sys_secret DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_read_policy ON sys_api;
DROP POLICY IF EXISTS api_write_policy ON sys_api;
ALTER TABLE sys_api DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_role_read_policy ON sys_user_role;
DROP POLICY IF EXISTS user_role_write_policy ON sys_user_role;
ALTER TABLE sys_user_role DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_api_read_policy ON sys_role_api;
DROP POLICY IF EXISTS role_api_write_policy ON sys_role_api;
ALTER TABLE sys_role_api DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS session_read_policy ON sys_user_session;
DROP POLICY IF EXISTS session_write_policy ON sys_user_session;
ALTER TABLE sys_user_session DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS blacklist_internal ON sys_token_blacklist;
ALTER TABLE sys_token_blacklist DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS request_read_policy ON sys_user_role_request;
DROP POLICY IF EXISTS request_write_policy ON sys_user_role_request;
ALTER TABLE sys_user_role_request DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_write_policy ON sys_role;
DROP POLICY IF EXISTS role_read_policy ON sys_role;
ALTER TABLE sys_role DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_write_policy ON sys_menu;
DROP POLICY IF EXISTS menu_read_policy ON sys_menu;
ALTER TABLE sys_menu DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dept_write_policy ON sys_department;
DROP POLICY IF EXISTS dept_tenant_isolation ON sys_department;
ALTER TABLE sys_department DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_dept_isolation_policy ON sys_user;
DROP POLICY IF EXISTS tenant_isolation_strict_policy ON sys_user;
ALTER TABLE sys_user DISABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS current_user_dept_id();
DROP FUNCTION IF EXISTS current_tenant_id();
DROP FUNCTION IF EXISTS current_user_id();
```

---

## 12. Migration 009：种子数据 + 初始密钥

**文件：** `db/migrations/20260707000009_seed_data.sql`

```sql
-- ==============================================================================
-- Migration 009: 种子数据（初始管理员、角色、菜单、API）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 步骤 1：生成 RSA 密钥对
-- 注意：以下私钥为测试用途，生产环境请替换为实际生成的 2048 位 RSA 私钥
-- ==============================================================================

-- 生成私钥（一次性执行，生产环境替换为实际密钥）
-- openssl genrsa -out private.pem 2048
-- openssl rsa -in private.pem -pubout -out public.pem

-- [修复 P0-2] JWT 签发已委托 Casdoor，不再存储 RSA 私钥
INSERT INTO sys_secret (key_name, key_value) VALUES
('casdoor_jwks_url', 'http://casdoor:8000/.well-known/jwks.json')
ON CONFLICT (key_name) DO UPDATE SET key_value = EXCLUDED.key_value;

-- ==============================================================================
-- 步骤 2：默认租户 + 默认部门
-- ==============================================================================
INSERT INTO sys_department (id, dept_name) VALUES 
('00000000-0000-0000-0000-000000000001', '默认部门')
ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at;

-- ==============================================================================
-- 步骤 3：默认管理员用户（密码：admin123）
-- ==============================================================================
INSERT INTO sys_user (id, username, password_hash, tenant_id, dept_id) VALUES 
(
    '00000000-0000-0000-0000-100000000001',
    'admin',
    crypt('admin123', gen_salt('bf', 10)),
    'tenant_default',
    '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT (username) DO UPDATE SET 
    password_hash = EXCLUDED.password_hash,
    tenant_id = EXCLUDED.tenant_id,
    dept_id = EXCLUDED.dept_id,
    updated_at = EXCLUDED.updated_at;

-- ==============================================================================
-- 步骤 4：默认角色
-- ==============================================================================
INSERT INTO sys_role (id, role_code, role_name, description) VALUES 
('00000000-0000-0000-0000-200000000001', 'super_admin', '超级管理员', '系统全部权限'),
('00000000-0000-0000-0000-200000000002', 'role_admin', '系统管理员', '权限管理系统'),
('00000000-0000-0000-0000-200000000003', 'role_editor', '编辑者', '可编辑内容'),
('00000000-0000-0000-0000-200000000004', 'role_guest', '访客', '只读访问')
ON CONFLICT (role_code) DO UPDATE SET 
    role_name = EXCLUDED.role_name,
    description = EXCLUDED.description,
    updated_at = EXCLUDED.updated_at;

-- 将 admin 绑定为超级管理员
INSERT INTO sys_user_role (user_id, role_id) VALUES 
('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000001')
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 步骤 5：默认菜单（管理后台基础导航树）
-- ==============================================================================

-- 根目录
INSERT INTO sys_menu (id, parent_id, type, name, path, component, title, icon, sort_order) VALUES
('00000000-0000-0000-0000-300000000001', NULL, 'DIR', 'System', '/system', 'Layout', '系统管理', 'setting', 1)
ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at;

-- 菜单项
INSERT INTO sys_menu (id, parent_id, type, name, path, component, title, icon, sort_order) VALUES
('00000000-0000-0000-0000-300000000002', '00000000-0000-0000-0000-300000000001', 'MENU', 'UserList', 'user', 'system/user/index', '用户管理', 'user', 1),
('00000000-0000-0000-0000-300000000003', '00000000-0000-0000-0000-300000000001', 'MENU', 'RoleList', 'role', 'system/role/index', '角色管理', 'peoples', 2),
('00000000-0000-0000-0000-300000000004', '00000000-0000-0000-0000-300000000001', 'MENU', 'MenuList', 'menu', 'system/menu/index', '菜单管理', 'tree-table', 3),
('00000000-0000-0000-0000-300000000005', '00000000-0000-0000-0000-300000000001', 'MENU', 'ApiList', 'api', 'system/api/index', 'API 管理', 'api', 4)
ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at;

-- 按钮权限
INSERT INTO sys_menu (id, parent_id, type, name, title, permission_code, sort_order) VALUES
('00000000-0000-0000-0000-300000000006', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserAdd', '新增用户', 'user:add', 1),
('00000000-0000-0000-0000-300000000007', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserEdit', '编辑用户', 'user:edit', 2),
('00000000-0000-0000-0000-300000000008', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserDelete', '删除用户', 'user:delete', 3)
ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at;

-- 超级管理员默认拥有所有菜单权限
INSERT INTO sys_role_menu (role_id, menu_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_menu
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 步骤 6：默认 API（PostgREST 基础端点）
-- ==============================================================================

-- 业务表 CRUD API
INSERT INTO sys_api (id, path, method, api_name) VALUES
('00000000-0000-0000-0000-400000000001', '/sys_user', 'GET', '查询用户列表'),
('00000000-0000-0000-0000-400000000002', '/sys_user', 'POST', '新增用户'),
('00000000-0000-0000-0000-400000000003', '/sys_user', 'PATCH', '更新用户'),
('00000000-0000-0000-0000-400000000004', '/sys_user', 'DELETE', '删除用户'),
('00000000-0000-0000-0000-400000000005', '/sys_role', 'GET', '查询角色列表'),
('00000000-0000-0000-0000-400000000006', '/sys_role', 'POST', '新增角色'),
('00000000-0000-0000-0000-400000000007', '/sys_role', 'PATCH', '更新角色'),
('00000000-0000-0000-0000-400000000008', '/sys_role', 'DELETE', '删除角色'),
('00000000-0000-0000-0000-400000000009', '/sys_menu', 'GET', '查询菜单列表'),
('00000000-0000-0000-0000-400000000010', '/sys_menu', 'POST', '新增菜单'),
('00000000-0000-0000-0000-400000000011', '/sys_menu', 'PATCH', '更新菜单'),
('00000000-0000-0000-0000-400000000012', '/sys_menu', 'DELETE', '删除菜单'),
('00000000-0000-0000-0000-400000000013', '/sys_api', 'GET', '查询API列表'),
('00000000-0000-0000-0000-400000000014', '/sys_api', 'POST', '新增API'),
('00000000-0000-0000-0000-400000000015', '/sys_api', 'PATCH', '更新API'),
('00000000-0000-0000-0000-400000000016', '/sys_api', 'DELETE', '删除API')
ON CONFLICT (id) DO UPDATE SET 
    api_name = EXCLUDED.api_name, path = EXCLUDED.path, method = EXCLUDED.method, updated_at = EXCLUDED.updated_at;

-- RPC 函数 API
INSERT INTO sys_api (id, path, method, api_name) VALUES
('00000000-0000-0000-0000-400000000017', '/rpc/get_user_menu', 'GET', '获取当前用户菜单树'),
('00000000-0000-0000-0000-400000000018', '/rpc/user_login_sso', 'POST', '用户登录'),
('00000000-0000-0000-0000-400000000019', '/rpc/refresh_token_rtr', 'POST', '刷新Token'),
('00000000-0000-0000-0000-400000000020', '/rpc/kick_user', 'POST', '踢用户下线'),
('00000000-0000-0000-0000-400000000021', '/rpc/approve_role_request', 'POST', '审批角色申请')
ON CONFLICT (id) DO UPDATE SET 
    api_name = EXCLUDED.api_name, path = EXCLUDED.path, method = EXCLUDED.method, updated_at = EXCLUDED.updated_at;

-- 超级管理员拥有所有 API 权限
INSERT INTO sys_role_api (role_id, api_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_api
ON CONFLICT DO NOTHING;

-- migrate:down

-- 注意：按依赖关系倒序删除
DELETE FROM sys_role_api WHERE role_id = '00000000-0000-0000-0000-200000000001';
DELETE FROM sys_api WHERE id LIKE '00000000-0000-0000-0000-4%';

DELETE FROM sys_role_menu WHERE role_id = '00000000-0000-0000-0000-200000000001';
DELETE FROM sys_menu WHERE id LIKE '00000000-0000-0000-0000-3%';

DELETE FROM sys_user_role WHERE user_id = '00000000-0000-0000-0000-100000000001';
DELETE FROM sys_role WHERE id LIKE '00000000-0000-0000-0000-2%';
DELETE FROM sys_user WHERE id = '00000000-0000-0000-0000-100000000001';
DELETE FROM sys_department WHERE id = '00000000-0000-0000-0000-000000000001';
DELETE FROM sys_secret WHERE key_name = 'jwt_private_key_pem';
```

---

## 13. Migration 执行验证

### 13.1 执行完 migration 后的验证

```powershell
# 1. 检查表数量（应为 11 张业务表）
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT COUNT(*) as table_count FROM information_schema.tables 
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
"

# 2. 检查视图（应为 1 个 casbin_rule 视图）
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT COUNT(*) as view_count FROM information_schema.views 
WHERE table_schema = 'public';
"

# 3. 检查函数（应为 8 个）
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT COUNT(*) as func_count FROM information_schema.routines 
WHERE routine_schema = 'public' AND routine_type = 'FUNCTION';
"

# 4. 检查触发器（应为 2 个）
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT trigger_name, event_object_table, action_statement 
FROM information_schema.triggers 
WHERE trigger_schema = 'public';
"

# 5. 检查 RLS 策略
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT tablename, policyname, cmd, qual, with_check 
FROM pg_policies 
WHERE schemaname = 'public';
"

# 6. 检查种子数据
docker exec app-postgres psql -U app_owner -d app_db -c "
SELECT 'roles' as category, COUNT(*) FROM sys_role
UNION ALL
SELECT 'users', COUNT(*) FROM sys_user
UNION ALL
SELECT 'menus', COUNT(*) FROM sys_menu
UNION ALL
SELECT 'apis', COUNT(*) FROM sys_api
UNION ALL
SELECT 'role_api', COUNT(*) FROM sys_role_api;
"
```

### 13.2 预期结果














---

## 14. pgTAP 测试（可选）

**文件：** `db/tests/test_basic.sql`

```sql
-- pgTAP 基础测试（需要 pg_tap 扩展）
BEGIN;
SELECT plan(8);

-- 测试 1：表存在
SELECT has_table('sys_user', '用户表存在');
SELECT has_table('sys_role', '角色表存在');
SELECT has_table('sys_menu', '菜单表存在');
SELECT has_table('sys_api', 'API表存在');
SELECT has_table('sys_user_role', '用户角色关联表存在');
SELECT has_table('sys_role_api', '角色API关联表存在');
SELECT has_table('sys_user_session', '会话表存在');
SELECT has_table('sys_token_blacklist', '黑名单表存在');

SELECT * FROM finish();
ROLLBACK;
```

```powershell
# 运行 pgTAP 测试
docker exec app-postgres pg_prove -U app_owner -d app_db db/tests/test_basic.sql
```

---

## 15. 常见问题

 解决方案 |
:---|
 `CREATE EXTENSION plpython3u;` |
 `CREATE EXTENSION pgcrypto;` |
 `dbmate status` 查看状态 |
 替换为 `openssl genrsa -out private.pem 2048` |
 确认 JWT 中 `tenant_id` 正确 |

---

## 16. 下一步

完成本文档后，Agent 可以：

1. ✅ 执行 `09-PostgREST完整配置.md` 中的 PostgREST 配置
2. ✅ 执行 `03-API与认证层.md` 中的接口验收

---

**✅ 阶段完成标志：** 11 张表 + 1 个视图 + 8 个函数 + 3 个触发器 + 5 个 RLS 策略 + 种子数据全部就绪。
**➡ 下一阶段：** `08-Docker-Compose` 已就绪，继续 `09-PostgREST完整配置`。