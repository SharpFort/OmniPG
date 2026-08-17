# 02 — 数据库建模：Schema、触发器与核心逻辑

> **定位：** 系统的核心——所有数据库 DDL、PL/pgSQL 函数、视图和触发器。Agent 按本文档的 migration 顺序逐一创建并验收。
> **前置依赖：** 01-环境搭建（PG 就绪、Dbmate 已安装、扩展已启用）
> **产出物：** `/db/migrations/` 目录下 9 个 migration 文件 + `/db/tests/` 下的 pgTAP 测试文件
> **预计耗时：** 3-6 小时

---

## 1. Migration 脚本规范

### 1.1 文件命名

```
/db/migrations/
├── 20260707001_init_tables.sql          # 基础表
├── 20260707002_init_relation_tables.sql  # 关联表 + 会话/黑名单/密钥表
├── 20260707003_create_casbin_view.sql   # casbin_rule 视图
├── 20260707004_notify_triggers.sql      # pg_notify 触发器
├── 20260707005_auth_functions.sql       # 认证函数（登录/刷新/黑名单检查）
├── 20260707006_permission_functions.sql # 权限管理函数（菜单/审批/踢人）
├── 20260707007_security_triggers.sql    # 安全触发器（角色变更即时生效）
├── 20260707008_rls_policies.sql         # RLS 行级安全策略
└── 20260707009_seed_data.sql            # 种子数据
```

### 1.2 编写规范

- 每个 migration 文件必须包含 `-- migrate:up` 和 `-- migrate:down` 两部分
- 所有 SQL 关键字使用大写
- 表名和列名使用小写 + 下划线
- 每张表、每个视图、每个函数必须添加 `COMMENT ON` 注释
- 涉及外部锁的大表操作需加 `-- dbmate:no-transaction` 标记
- 生产环境禁止回滚，采用 roll-forward 策略（新 migration 修复旧 migration 的问题）

---

## 2. Migration 001：基础表

**文件：** `20260707001_init_tables.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 1. 密钥配置表（仅 SECURITY DEFINER 函数可读）
-- ==============================================================================
CREATE TABLE sys_secret (
    key_name VARCHAR(100) PRIMARY KEY,
    key_value TEXT NOT NULL
);
COMMENT ON TABLE sys_secret IS '系统密钥存储表，存放 JWT 私钥等敏感配置';

-- ==============================================================================
-- 2. 部门表（支持树形结构）
-- ==============================================================================
CREATE TABLE sys_department (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dept_name VARCHAR(100) NOT NULL,
    parent_id UUID REFERENCES sys_department(id) ON DELETE CASCADE
);
COMMENT ON TABLE sys_department IS '部门组织架构表';
COMMENT ON COLUMN sys_department.parent_id IS '上级部门 ID，NULL 表示根部门';

-- ==============================================================================
-- 3. 用户表（含租户和部门字段）
-- ==============================================================================
CREATE TABLE sys_user (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    tenant_id VARCHAR(50) NOT NULL,
    dept_id UUID REFERENCES sys_department(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_user IS '用户表，含多租户和部门关联';
COMMENT ON COLUMN sys_user.tenant_id IS '租户标识，用于多租户行级隔离';
COMMENT ON COLUMN sys_user.dept_id IS '所属部门，用于数据级权限过滤';
CREATE INDEX idx_user_tenant_dept ON sys_user(tenant_id, dept_id);
CREATE INDEX idx_user_username ON sys_user(username);

-- ==============================================================================
-- 4. 角色表
-- ==============================================================================
CREATE TABLE sys_role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code VARCHAR(50) NOT NULL UNIQUE,
    role_name VARCHAR(100) NOT NULL
);
COMMENT ON TABLE sys_role IS '角色表';
COMMENT ON COLUMN sys_role.role_code IS '角色代码（英文标识），写入 JWT 的 roles 数组';
CREATE INDEX idx_role_code ON sys_role(role_code);

-- ==============================================================================
-- 5. API 资源表（后端权限防御对象）
-- ==============================================================================
CREATE TABLE sys_api (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    path VARCHAR(255) NOT NULL,
    method VARCHAR(10) NOT NULL,
    api_name VARCHAR(100)
);
COMMENT ON TABLE sys_api IS 'API 资源表，定义后端接口的边界防御规则';
COMMENT ON COLUMN sys_api.path IS 'API 路径模式，支持 :id 通配符';
COMMENT ON COLUMN sys_api.method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH';
CREATE INDEX idx_api_path_method ON sys_api(path, method);
CREATE UNIQUE INDEX idx_api_path_method_unique ON sys_api(path, method);

-- ==============================================================================
-- 6. 菜单与前权限标识表
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
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_menu IS '菜单与前端权限表：DIR=目录, MENU=页面菜单, BUTTON=按钮';
COMMENT ON COLUMN sys_menu.permission_code IS '按钮权限标识，如 user:add，仅 type=BUTTON 时使用';
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

## 3. Migration 002：关联表 + 会话/黑名单表

**文件：** `20260707002_init_relation_tables.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 7. 用户-角色关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_user_role (
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE,
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE sys_user_role IS '用户-角色关联表';

-- ==============================================================================
-- 8. 角色-API 关联表（M:N，网关层 Casbin 数据源）
-- ==============================================================================
CREATE TABLE sys_role_api (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    api_id UUID REFERENCES sys_api(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, api_id)
);
COMMENT ON TABLE sys_role_api IS '角色-API 关联表，casbin_rule 视图的 p 规则数据源';

-- ==============================================================================
-- 9. 角色-菜单关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_role_menu (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    menu_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, menu_id)
);
COMMENT ON TABLE sys_role_menu IS '角色-菜单关联表';

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
COMMENT ON COLUMN sys_user_session.active_jti IS '当前活跃的 Access Token JTI，用于角色变更即时踢下线';
CREATE INDEX idx_session_user ON sys_user_session(user_id, is_used);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);

-- ==============================================================================
-- 11. Token 黑名单表
-- ==============================================================================
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY,
    blacklisted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL
);
COMMENT ON TABLE sys_token_blacklist IS 'Access Token 黑名单，配合 db-pre-request 实现踢下线';
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);

-- migrate:down
DROP TABLE IF EXISTS sys_token_blacklist CASCADE;
DROP TABLE IF EXISTS sys_user_session CASCADE;
DROP TABLE IF EXISTS sys_role_menu CASCADE;
DROP TABLE IF EXISTS sys_role_api CASCADE;
DROP TABLE IF EXISTS sys_user_role CASCADE;
```

---

## 4. Migration 003：casbin_rule 视图

**文件：** `20260707003_create_casbin_view.sql`

```sql
-- migrate:up

-- ==============================================================================
-- casbin_rule 视图（Role-in-JWT 优化后，仅保留 p 规则）
-- ==============================================================================
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
JOIN sys_role r ON ra.role_id = r.id
JOIN sys_api a ON ra.api_id = a.id;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径模式';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法';

-- migrate:down
DROP VIEW IF EXISTS casbin_rule CASCADE;
```

---

## 5. Migration 004：pg_notify 通知触发器

**文件：** `20260707004_notify_triggers.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 广播函数：当 sys_role_api 变更时发送 pg_notify
-- ==============================================================================
CREATE OR REPLACE FUNCTION notify_policy_reload()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('casbin_channel', 'reload');
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION notify_policy_reload() IS '发送 casbin_channel 通知，触发 Policy Syncer 同步';

-- 绑定触发器到角色-API 关联表（FOR EACH STATEMENT 防止高频写入风暴）
CREATE TRIGGER trg_reload_on_role_api
AFTER INSERT OR UPDATE OR DELETE ON sys_role_api
FOR EACH STATEMENT EXECUTE FUNCTION notify_policy_reload();

-- migrate:down
DROP TRIGGER IF EXISTS trg_reload_on_role_api ON sys_role_api;
DROP FUNCTION IF EXISTS notify_policy_reload();
```

---

## 6. Migration 005：认证函数（登录、刷新、黑名单检查）

**文件：** `20260707005_auth_functions.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 0. 辅助函数：sha256 包装 + generate_rs256_jwt
-- ==============================================================================

-- sha256 包装函数：封装 pgcrypto 的 digest() 为易用的 sha256()
CREATE OR REPLACE FUNCTION sha256(data bytea) 
RETURNS text AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$ LANGUAGE sql IMMUTABLE STRICT;
COMMENT ON FUNCTION sha256(bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值';

-- generate_rs256_jwt：使用 plpython3u + PyJWT 生成 RS256 签名的 JWT
CREATE OR REPLACE FUNCTION generate_rs256_jwt(
    p_payload jsonb,
    p_private_key text,
    p_key_id text DEFAULT 'key-v1'
)
RETURNS text AS $$
    import json
    import jwt
    payload = json.loads(p_payload)
    headers = {"kid": p_key_id, "alg": "RS256"}
    token = jwt.encode(payload, p_private_key, algorithm="RS256", headers=headers)
    return token
$$ LANGUAGE plpython3u SECURITY DEFINER;
COMMENT ON FUNCTION generate_rs256_jwt(jsonb, text, text) IS '使用 RS256 算法签发 JWT。依赖 plpython3u + PyJWT 库。p_payload 不含 key_id 时默认使用 key-v1';

-- ==============================================================================
-- 1. check_token_blacklist：PostgREST db-pre-request 函数
-- ==============================================================================
CREATE OR REPLACE FUNCTION check_token_blacklist()
RETURNS void AS $$
DECLARE
    v_jti varchar;
BEGIN
    v_jti := current_setting('request.jwt.claims', true)::json->>'jti';

    IF v_jti IS DISTINCT FROM NULL AND EXISTS (
        SELECT 1 FROM sys_token_blacklist WHERE jti = v_jti
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
    -- 验证用户密码并获取租户/部门信息
    SELECT id, tenant_id, dept_id, password_hash INTO v_user 
    FROM sys_user WHERE username = p_username;
    
    IF NOT FOUND OR v_user.password_hash IS DISTINCT FROM crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = 'P0001';
    END IF;

    -- 聚合该用户的所有角色代码
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id;
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- SSO：作废该用户旧的活跃会话
    UPDATE sys_user_session SET is_used = TRUE WHERE user_id = v_user.id AND is_used = FALSE;

    -- 生成新会话
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_user.id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 构造 JWT Payload
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_user.id::text,
        'username', p_username,
        'tenant_id', v_user.tenant_id,
        'dept_id', COALESCE(v_user.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    -- 读取私钥并签名
    SELECT key_value INTO v_private_key FROM sys_secret WHERE key_name = 'jwt_private_key_pem';
    IF v_private_key IS NULL THEN
        RAISE EXCEPTION 'Cryptographic private key not configured' USING ERRCODE = 'P0003';
    END IF;

    v_new_at := generate_rs256_jwt(v_payload, v_private_key, 'key-v1');

    -- 注入 httpOnly Cookie
    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; Secure; SameSite=Strict; Max-Age=604800"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

    RETURN json_build_object(
        'access_token', v_new_at,
        'username', p_username
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
    v_roles_json jsonb;
    v_user RECORD;
    v_jti varchar;
    v_new_rt varchar;
    v_new_rt_hash varchar;
    v_private_key text;
    v_payload jsonb;
    v_new_at varchar;
    v_cookie_header text;
BEGIN
    v_old_rt_hash := sha256(p_old_rt::bytea);

    SELECT s.*, u.username, u.tenant_id, u.dept_id 
    INTO v_session
    FROM sys_user_session s
    JOIN sys_user u ON s.user_id = u.id
    WHERE s.refresh_token_hash = v_old_rt_hash;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid Session' USING ERRCODE = 'P0001';
    END IF;

    -- RTR 防重放：如果旧 RT 已被使用，则发生盗用，全端下线
    IF v_session.is_used = TRUE THEN
        DELETE FROM sys_user_session WHERE user_id = v_session.user_id;
        RAISE EXCEPTION 'Security Breach Detected: Replay Attack! All sessions revoked.' USING ERRCODE = 'P0002';
    END IF;

    IF v_session.expired_at < NOW() THEN
        DELETE FROM sys_user_session WHERE id = v_session.id;
        RAISE EXCEPTION 'Session Expired' USING ERRCODE = 'P0001';
    END IF;

    -- 作废旧 RT
    UPDATE sys_user_session SET is_used = TRUE WHERE id = v_session.id;

    -- 获取最新角色
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_session.user_id;
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 生成新会话
    v_jti := gen_random_uuid()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_session.user_id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 构造新 JWT Payload（含最新角色）
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_session.user_id::text,
        'username', v_session.username,
        'tenant_id', v_session.tenant_id,
        'dept_id', COALESCE(v_session.dept_id::text, ''),
        'roles', v_roles_json,
        'exp', extract(epoch from now() + interval '15 minutes')::integer
    )::jsonb;

    SELECT key_value INTO v_private_key FROM sys_secret WHERE key_name = 'jwt_private_key_pem';
    v_new_at := generate_rs256_jwt(v_payload, v_private_key, 'key-v1');

    v_cookie_header := format(
        '[{"Set-Cookie": "refresh_token=%s; Path=/rpc/refresh_token; HttpOnly; Secure; SameSite=Strict; Max-Age=604800"}]',
        v_new_rt
    );
    PERFORM set_config('response.headers', v_cookie_header, true);

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
    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = p_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at)
        VALUES (v_session.active_jti, v_session.expired_at)
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

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
```

---

## 7. Migration 006：权限管理函数

**文件：** `20260707006_permission_functions.sql`

```sql
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
-- 2. approve_role_request：审批角色申请
-- ==============================================================================
-- 先创建审批流表
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    applicant_id UUID NOT NULL,
    approver_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP WITH TIME ZONE
);
COMMENT ON TABLE sys_user_role_request IS '角色分配审批流表';

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
    SET status = 'approved', approver_id = v_approver_id, approved_at = now()
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

## 8. Migration 007：安全触发器

**文件：** `20260707007_security_triggers.sql`

```sql
-- migrate:up

-- ==============================================================================
-- blacklist_at_on_role_change：角色变更时即时使旧 Token 失效
-- ==============================================================================
CREATE OR REPLACE FUNCTION blacklist_at_on_role_change()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id uuid;
    v_session RECORD;
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') THEN
        v_user_id := NEW.user_id;
    ELSE
        v_user_id := OLD.user_id;
    END IF;

    FOR v_session IN 
        SELECT active_jti, expired_at 
        FROM sys_user_session 
        WHERE user_id = v_user_id AND is_used = FALSE AND active_jti IS NOT NULL
    LOOP
        INSERT INTO sys_token_blacklist (jti, expired_at)
        VALUES (v_session.active_jti, v_session.expired_at)
        ON CONFLICT (jti) DO NOTHING;
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION blacklist_at_on_role_change() IS '角色变更触发器：将旧 JWT 的 jti 写入黑名单，迫使客户端无感刷新';

CREATE TRIGGER trg_blacklist_on_role_change
AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
FOR EACH ROW EXECUTE FUNCTION blacklist_at_on_role_change();

-- migrate:down
DROP TRIGGER IF EXISTS trg_blacklist_on_role_change ON sys_user_role;
DROP FUNCTION IF EXISTS blacklist_at_on_role_change();
```

---

## 9. Migration 008：RLS 行级安全策略

**文件：** `20260707008_rls_policies.sql`

```sql
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
-- sys_user 表：多租户隔离 + 部门数据隔离
-- ==============================================================================
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_strict_policy ON sys_user
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY employee_dept_isolation_policy ON sys_user
FOR SELECT
USING (
    current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin'
    OR dept_id = current_user_dept_id()
    OR id = current_user_id()
);

-- ==============================================================================
-- sys_role 等管理表：仅超级管理员可写（通过 PostgREST 配置的 role 控制）
-- 行级只读对所有认证用户开放
-- ==============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;
CREATE POLICY role_tenant_isolation ON sys_role
AS RESTRICTIVE
USING (true);  -- 角色表通常不按租户隔离，按需调整

-- migrate:down
DROP POLICY IF EXISTS role_tenant_isolation ON sys_role;
ALTER TABLE sys_role DISABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_dept_isolation_policy ON sys_user;
DROP POLICY IF EXISTS tenant_isolation_strict_policy ON sys_user;
ALTER TABLE sys_user DISABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS current_user_dept_id();
DROP FUNCTION IF EXISTS current_tenant_id();
DROP FUNCTION IF EXISTS current_user_id();
```

---

## 10. Migration 009：种子数据

**文件：** `20260707009_seed_data.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 初始密钥（私钥需要替换为实际生成的 RSA 私钥）
-- ==============================================================================
INSERT INTO sys_secret (key_name, key_value) VALUES 
('jwt_private_key_pem', '-----BEGIN RSA PRIVATE KEY-----
[此处替换为实际生成的 2048 位 RSA 私钥 PEM]
-----END RSA PRIVATE KEY-----')
ON CONFLICT (key_name) DO NOTHING;

-- ==============================================================================
-- 默认租户 + 默认部门
-- ==============================================================================
INSERT INTO sys_department (id, dept_name) VALUES 
('00000000-0000-0000-0000-000000000001', '默认部门')
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 默认管理员用户（密码：admin123）
-- ==============================================================================
INSERT INTO sys_user (id, username, password_hash, tenant_id, dept_id) VALUES 
('00000000-0000-0000-0000-100000000001', 'admin', 
 crypt('admin123', gen_salt('bf', 10)), 
 'tenant_default', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (username) DO NOTHING;

-- ==============================================================================
-- 默认角色
-- ==============================================================================
INSERT INTO sys_role (id, role_code, role_name) VALUES 
('00000000-0000-0000-0000-200000000001', 'super_admin', '超级管理员'),
('00000000-0000-0000-0000-200000000002', 'role_admin', '系统管理员'),
('00000000-0000-0000-0000-200000000003', 'role_editor', '编辑者'),
('00000000-0000-0000-0000-200000000004', 'role_guest', '访客')
ON CONFLICT (role_code) DO NOTHING;

-- 将 admin 绑定为超级管理员
INSERT INTO sys_user_role (user_id, role_id) VALUES 
('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000001')
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 默认菜单（管理后台基础导航）
-- ==============================================================================
INSERT INTO sys_menu (id, parent_id, type, name, path, component, title, icon, sort_order) VALUES
('00000000-0000-0000-0000-300000000001', NULL, 'DIR', 'System', '/system', 'Layout', '系统管理', 'setting', 1),
('00000000-0000-0000-0000-300000000002', '00000000-0000-0000-0000-300000000001', 'MENU', 'UserList', 'user', 'system/user/index', '用户管理', 'user', 1),
('00000000-0000-0000-0000-300000000003', '00000000-0000-0000-0000-300000000001', 'MENU', 'RoleList', 'role', 'system/role/index', '角色管理', 'peoples', 2),
('00000000-0000-0000-0000-300000000004', '00000000-0000-0000-0000-300000000001', 'MENU', 'MenuList', 'menu', 'system/menu/index', '菜单管理', 'tree-table', 3),
('00000000-0000-0000-0000-300000000005', '00000000-0000-0000-0000-300000000001', 'MENU', 'ApiList', 'api', 'system/api/index', 'API 管理', 'api', 4)
ON CONFLICT DO NOTHING;

-- 按钮权限
INSERT INTO sys_menu (id, parent_id, type, name, title, permission_code, sort_order) VALUES
('00000000-0000-0000-0000-300000000006', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserAdd', '新增用户', 'user:add', 1),
('00000000-0000-0000-0000-300000000007', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserEdit', '编辑用户', 'user:edit', 2),
('00000000-0000-0000-0000-300000000008', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserDelete', '删除用户', 'user:delete', 3)
ON CONFLICT DO NOTHING;

-- 超级管理员默认拥有所有菜单权限
INSERT INTO sys_role_menu (role_id, menu_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_menu
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 默认 API（PostgREST 基础 CRUD 端点）
-- ==============================================================================
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
('00000000-0000-0000-0000-400000000016', '/sys_api', 'DELETE', '删除API'),
('00000000-0000-0000-0000-400000000017', '/rpc/get_user_menu', 'GET', '获取当前用户菜单树'),
('00000000-0000-0000-0000-400000000018', '/rpc/user_login_sso', 'POST', '用户登录'),
('00000000-0000-0000-0000-400000000019', '/rpc/refresh_token_rtr', 'POST', '刷新Token'),
('00000000-0000-0000-0000-400000000020', '/rpc/kick_user', 'POST', '踢用户下线'),
('00000000-0000-0000-0000-400000000021', '/rpc/approve_role_request', 'POST', '审批角色申请')
ON CONFLICT DO NOTHING;

-- 超级管理员拥有所有 API 权限
INSERT INTO sys_role_api (role_id, api_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_api
ON CONFLICT DO NOTHING;

-- migrate:down
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

## 11. 验收清单

Agent 完成所有 migration 后，逐项执行以下验收：

| # | 验收项 | 验证方法 | 通过 |
|:---:|:---|:---|:---:|
| D1 | 11 张基础表全部存在 | `\dt sys_*` 或 `SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'sys_%'` | ☐ |
| D2 | casbin_rule 视图可查询 | `SELECT COUNT(*) FROM casbin_rule`（初始为 21 条，对应种子数据中 21 个 API） | ☐ |
| D3 | user_login_sso 可调用并返回双 Token | `SELECT user_login_sso('admin', 'admin123')` → JSON 含 access_token | ☐ |
| D4 | get_user_menu 返回 JSON 菜单树 | 用 `curl` 带 admin JWT 调用 `/rpc/get_user_menu` → 返回含 children 和 buttons 的嵌套 JSON | ☐ |
| D5 | pg_notify 触发器正常 | 会话 A: `LISTEN casbin_channel;` 会话 B: `INSERT INTO sys_role_api ...` → 会话 A 收到通知 | ☐ |
| D6 | Token 黑名单生效 | `INSERT INTO sys_token_blacklist (jti, expired_at) VALUES ('test-jti', now()+interval '1 hour');` → 调用 `SELECT check_token_blacklist()` 时应抛异常 | ☐ |
| D7 | RLS 策略生效 | 用不同 tenant_id 的 JWT 查询 `sys_user` → 只返回本租户数据 | ☐ |
| D8 | 角色变更触发器生效 | `INSERT INTO sys_user_role` → `SELECT * FROM sys_token_blacklist` → 应有对应的 jti 记录 | ☐ |
| D9 | refresh_token_rtr 可正常刷新 | 用登录返回的 refresh_token 调用 refresh_token_rtr → 返回新双 Token | ☐ |
| D10 | Dbmate status 全部已执行 | `dbmate status` → 所有 migration 显示 `up` | ☐ |

> **通过标准：** 10/10 项全部打勾。任一未通过则修复后重新验收。
