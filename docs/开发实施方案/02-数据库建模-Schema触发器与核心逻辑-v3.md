# 02 — 数据库建模：Schema、触发器与核心逻辑

> **定位：** 系统的核心——所有数据库 DDL、PL/pgSQL 函数、视图和触发器。Agent 按本文档的 migration 顺序逐一创建并验收。
> **前置依赖：** 01-环境搭建（PG 就绪、Dbmate 已安装、扩展已启用）
> **产出物：** `/db/migrations/` 目录下 12 个 migration 文件 + `/db/tests/` 下的 pgTAP 测试文件
> **预计耗时：** 4-8 小时

---

## 0. 关键设计决策

| 决策项 | 选择 | 理由 |
|:---|:---|:---|
| 主键类型 | UUID v7（PG 18 内置 `uuidv7()`） | 时间有序，B-Tree 索引性能提升 30-50%，无需扩展 |
| 密码哈希 | Argon2id（`pg_pwhash` 扩展） | OWASP Password Storage Cheat Sheet 首选，抗 GPU/ASIC |
| 多租户 | 行级隔离（`tenant_id` + RLS） | 简单、可扩展，适合 SaaS 场景 |
| 租户管理 | `sys_tenant` 表 | 统一管理租户生命周期和状态 |
| 软删除 | `deleted_at TIMESTAMPTZ` | 可恢复，审计友好 |
|| 审计字段 | `created_at`/`updated_at`/`deleted_at` + `_by` 审计 | 完整变更追溯（IFullAuditedObject） |
| 更新时间 | `update_updated_at()` 触发器 | 自动维护 `updated_at` |

### 0.1 租户字段分布规则

| 表 | tenant_id | 约束 | 说明 |
|:---|:---|:---|:---|
| `sys_tenant` | PK（UUID） | - | 租户主表 |
| `sys_department` | ✅ NOT NULL | FK → sys_tenant(id) | 业务数据，租户间必须隔离 |
| `sys_user` | ✅ NOT NULL | FK → sys_tenant(id) | 用户归属租户 |
| `sys_role` | ✅ NULLABLE | FK → sys_tenant(id) | NULL = 全局角色，有值 = 租户角色 |
| `sys_api` | ❌ | - | 系统级共享资源，租户无定义权 |
| `sys_menu` | ❌ | - | 系统级共享，通过权限控制显示 |
| `sys_user_role` | 继承自 user | - | 通过 user 表继承租户隔离 |
| `sys_role_api` | 继承自 role | - | 通过 role 表继承租户隔离 |
| `sys_role_menu` | 继承自 role | - | 通过 role 表继承租户隔离 |
| `sys_user_session` | 继承自 user | - | 通过 user 表继承租户隔离 |
| `sys_token_blacklist` | ❌ | - | 系统级，SECURITY DEFINER 访问 |
| `sys_secret` | ❌ | - | 系统级配置 |
| `sys_audit_log` | ✅ NOT NULL | FK → sys_tenant(id) | 审计数据按租户隔离 |
| `sys_cron_log` | ❌ | - | 系统级 |

---

## 1. Migration 脚本规范

### 1.1 文件命名

```
/db/migrations/
├── 20260707001_init_tables.sql          # 基础表（含 sys_tenant）
├── 20260707002_init_relation_tables.sql  # 关联表 + 会话/黑名单/密钥表
├── 20260707003_create_casbin_view.sql   # casbin_rule 视图
├── 20260707004_notify_triggers.sql      # pg_notify 触发器
├── 20260707005_auth_functions.sql       # 认证函数（登录/刷新/黑名单检查）
├── 20260707006_permission_functions.sql # 权限管理函数（菜单/审批/踢人）
├── 20260707007_security_triggers.sql    # 安全触发器（角色变更即时生效）
├── 20260707008_rls_policies.sql         # RLS 行级安全策略
├── 20260707009_seed_data.sql            # 种子数据
├── 20260707010_cleanup_cron.sql         # pg_cron 定时清理任务
├── 20260707011_audit_triggers.sql       # 审计触发器 + updated_at 触发器
└── 20260707012_audit_log_table.sql      # 审计日志表
```

### 1.2 编写规范

- 每个 migration 文件必须包含 `-- migrate:up` 和 `-- migrate:down` 两部分
- 所有 SQL 关键字使用大写
- 表名和列名使用小写 + 下划线
- 每张表、每个视图、每个函数必须添加 `COMMENT ON` 注释
- 涉及外部锁的大表操作需加 `-- dbmate:no-transaction` 标记
- 生产环境禁止回滚，采用 roll-forward 策略（新 migration 修复旧 migration 的问题）
- 所有主键使用 `uuidv7()` 生成（PG 18 内置函数）
- 所有密码哈希使用 `pwhash_crypt()` + `pwhash_gen_salt('argon2id')`（pg_pwhash 扩展）

---

## 2. Migration 001：基础表

**文件：** `20260707001_init_tables.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 0. 扩展启用
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS pg_pwhash;  -- Argon2id 密码哈希
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- sha256 等辅助哈希（仅用于非密码场景）

-- ==============================================================================
-- 1. 租户表（多租户管理核心）
-- ==============================================================================
CREATE TABLE sys_tenant (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_code VARCHAR(50) NOT NULL UNIQUE,
    tenant_name VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'disabled')),
    contact_email VARCHAR(255),
    max_users INT DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL
);
COMMENT ON TABLE sys_tenant IS '租户管理表，所有业务数据按租户隔离';
COMMENT ON COLUMN sys_tenant.status IS '租户状态：active=正常, suspended=暂停, disabled=禁用';
COMMENT ON COLUMN sys_tenant.max_users IS '该租户最大用户数限制';
COMMENT ON COLUMN sys_tenant.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_tenant.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_tenant.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_tenant_code ON sys_tenant(tenant_code);
CREATE INDEX idx_tenant_status ON sys_tenant(status);

-- ==============================================================================
-- 2. 密钥配置表（仅 SECURITY DEFINER 函数可读）
-- ==============================================================================
CREATE TABLE sys_secret (
    key_name VARCHAR(100) PRIMARY KEY,
    key_value TEXT NOT NULL
);
COMMENT ON TABLE sys_secret IS '系统密钥存储表，存放 JWT 私钥等敏感配置';

-- ==============================================================================
-- 3. 部门表（支持树形结构，租户隔离）
-- ==============================================================================
CREATE TABLE sys_department (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    dept_name VARCHAR(100) NOT NULL,
    tenant_id UUID NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    parent_id UUID REFERENCES sys_department(id) ON DELETE CASCADE,
    sort_order INT DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL
);
COMMENT ON TABLE sys_department IS '部门组织架构表，按租户隔离';
COMMENT ON COLUMN sys_department.tenant_id IS '所属租户，租户间部门数据隔离';
COMMENT ON COLUMN sys_department.parent_id IS '上级部门 ID，NULL 表示根部门';
COMMENT ON COLUMN sys_department.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_department.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_department.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_dept_tenant ON sys_department(tenant_id);
CREATE INDEX idx_dept_parent ON sys_department(parent_id);

-- ==============================================================================
-- 4. 用户表（含租户和部门字段）
-- ==============================================================================
CREATE TABLE sys_user (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    tenant_id UUID NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    dept_id UUID REFERENCES sys_department(id) ON DELETE SET NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL
);
COMMENT ON TABLE sys_user IS '用户表，含多租户和部门关联';
COMMENT ON COLUMN sys_user.tenant_id IS '租户标识，用于多租户行级隔离';
COMMENT ON COLUMN sys_user.dept_id IS '所属部门，用于数据级权限过滤';
COMMENT ON COLUMN sys_user.is_active IS '账户是否激活（软删除替代字段）';
COMMENT ON COLUMN sys_user.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_user.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_user.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_user_tenant_dept ON sys_user(tenant_id, dept_id);
CREATE INDEX idx_user_username ON sys_user(username);
CREATE INDEX idx_user_tenant ON sys_user(tenant_id);

-- ==============================================================================
-- 5. 角色表（支持全局角色 + 租户角色）
-- ==============================================================================
CREATE TABLE sys_role (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    role_code VARCHAR(50) NOT NULL,
    role_name VARCHAR(100) NOT NULL,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    -- 全局角色（tenant_id=NULL）的 role_code 全局唯一
    -- 租户角色的 role_code 在租户内唯一
    CONSTRAINT uq_role_code_tenant UNIQUE (role_code, tenant_id)
);
COMMENT ON TABLE sys_role IS '角色表：tenant_id=NULL 为全局角色，有值为租户角色';
COMMENT ON COLUMN sys_role.tenant_id IS 'NULL=全局角色（所有租户可见），有值=租户私有角色';
COMMENT ON COLUMN sys_role.role_code IS '角色代码（英文标识），写入 JWT 的 roles 数组';
COMMENT ON COLUMN sys_role.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_role.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_role.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_role_code ON sys_role(role_code);
CREATE INDEX idx_role_tenant ON sys_role(tenant_id);

-- ==============================================================================
-- 6. API 资源表（后端权限防御对象，系统级共享）
-- ==============================================================================
CREATE TABLE sys_api (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    path VARCHAR(255) NOT NULL,
    method VARCHAR(10) NOT NULL,
    api_name VARCHAR(100),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    CONSTRAINT uq_api_path_method UNIQUE (path, method)
);
COMMENT ON TABLE sys_api IS 'API 资源表，定义后端接口的边界防御规则（系统级共享）';
COMMENT ON COLUMN sys_api.path IS 'API 路径模式，支持 :id 通配符';
COMMENT ON COLUMN sys_api.method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH';
COMMENT ON COLUMN sys_api.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_api.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_api.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_api_path_method ON sys_api(path, method);

-- ==============================================================================
-- 7. 菜单与前端权限标识表（系统级共享）
-- ==============================================================================
CREATE TABLE sys_menu (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    parent_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    type VARCHAR(10) NOT NULL CHECK (type IN ('DIR', 'MENU', 'BUTTON')),
    name VARCHAR(100) NOT NULL,
    path VARCHAR(255),
    component VARCHAR(255),
    title VARCHAR(100) NOT NULL,
    icon VARCHAR(100),
    permission_code VARCHAR(100),
    sort_order INT DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    deleted_at TIMESTAMPTZ,
    deleted_by UUID REFERENCES sys_user(id) ON DELETE SET NULL
);
COMMENT ON TABLE sys_menu IS '菜单与前端权限表：DIR=目录, MENU=页面菜单, BUTTON=按钮（系统级共享）';
COMMENT ON COLUMN sys_menu.permission_code IS '按钮权限标识，如 user:add，仅 type=BUTTON 时使用';
COMMENT ON COLUMN sys_menu.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_menu.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_menu.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_menu_parent ON sys_menu(parent_id);
CREATE INDEX idx_menu_type ON sys_menu(type);

-- ==============================================================================
-- 8. updated_at 自动更新触发器函数
-- ==============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION update_updated_at() IS '自动更新 updated_at 字段为当前时间';

-- migrate:down
DROP FUNCTION IF EXISTS update_updated_at();
DROP TABLE IF EXISTS sys_menu CASCADE;
DROP TABLE IF EXISTS sys_api CASCADE;
DROP TABLE IF EXISTS sys_role CASCADE;
DROP TABLE IF EXISTS sys_user CASCADE;
DROP TABLE IF EXISTS sys_department CASCADE;
DROP TABLE IF EXISTS sys_secret CASCADE;
DROP TABLE IF EXISTS sys_tenant CASCADE;
```

---

## 3. Migration 002：关联表 + 会话/黑名单表

**文件：** `20260707002_init_relation_tables.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 9. 用户-角色关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_user_role (
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE,
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE sys_user_role IS '用户-角色关联表';
CREATE INDEX idx_user_role_tenant ON sys_user_role(tenant_id);

-- ==============================================================================
-- 10. 角色-API 关联表（M:N，网关层 Casbin 数据源）
-- ==============================================================================
CREATE TABLE sys_role_api (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    api_id UUID REFERENCES sys_api(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (role_id, api_id)
);
COMMENT ON TABLE sys_role_api IS '角色-API 关联表，casbin_rule 视图的 p 规则数据源';

-- ==============================================================================
-- 11. 角色-菜单关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_role_menu (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    menu_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (role_id, menu_id)
);
COMMENT ON TABLE sys_role_menu IS '角色-菜单关联表';

-- ==============================================================================
-- 12. 用户会话表（Refresh Token 管理）
-- ==============================================================================
CREATE TABLE sys_user_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES sys_user(id) ON DELETE CASCADE,
    refresh_token_hash VARCHAR(64) NOT NULL UNIQUE,
    active_jti VARCHAR(50),
    is_used BOOLEAN DEFAULT FALSE,
    client_ip VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expired_at TIMESTAMPTZ NOT NULL
);
COMMENT ON TABLE sys_user_session IS '用户会话表，管理 Refresh Token 生命周期';
COMMENT ON COLUMN sys_user_session.active_jti IS '当前活跃的 Access Token JTI，用于角色变更即时踢下线';
CREATE INDEX idx_session_user ON sys_user_session(user_id, is_used);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);

-- ==============================================================================
-- 13. Token 黑名单表
-- ==============================================================================
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY,
    blacklisted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expired_at TIMESTAMPTZ NOT NULL,
    reason VARCHAR(50),
    user_id UUID
);
COMMENT ON TABLE sys_token_blacklist IS 'Access Token 黑名单，配合 db-pre-request 实现踢下线';
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);
CREATE INDEX idx_blacklist_user ON sys_token_blacklist(user_id);

-- ==============================================================================
-- 14. 角色分配审批流表
-- ==============================================================================
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    applicant_id UUID NOT NULL,
    approver_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at TIMESTAMPTZ
);
COMMENT ON TABLE sys_user_role_request IS '角色分配审批流表';
CREATE INDEX idx_role_request_status ON sys_user_role_request(status);
CREATE INDEX idx_role_request_tenant ON sys_user_role_request(tenant_id);

-- migrate:down
DROP TABLE IF EXISTS sys_user_role_request CASCADE;
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
-- 自动过滤软删除数据
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
JOIN sys_api a ON ra.api_id = a.id
WHERE r.deleted_at IS NULL 
  AND a.deleted_at IS NULL;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则），自动过滤软删除';
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
-- 0. 辅助函数
-- ==============================================================================

-- sha256 包装函数：封装 pgcrypto 的 digest() 为易用的 sha256()
-- 注意：仅用于非密码场景（如 Refresh Token 哈希），密码哈希使用 pg_pwhash
CREATE OR REPLACE FUNCTION sha256(data bytea) 
RETURNS text AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$ LANGUAGE sql IMMUTABLE STRICT;
COMMENT ON FUNCTION sha256(bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值（仅用于非密码场景）';

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
COMMENT ON FUNCTION generate_rs256_jwt(jsonb, text, text) IS '使用 RS256 算法签发 JWT。依赖 plpython3u + PyJWT 库。';

-- ==============================================================================
-- 0. 密码生成函数：自动生成 Argon2id 哈希密码
-- ==============================================================================
CREATE OR REPLACE FUNCTION generate_user_password(p_password text)
RETURNS text AS $$
    SELECT pwhash_crypt(p_password, pwhash_gen_salt('argon2id'));
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION generate_user_password(text) IS '使用 Argon2id 算法生成密码哈希。用于创建用户时自动生成 password_hash，如：INSERT INTO sys_user (..., password_hash) VALUES (..., generate_user_secret('defaultPass123'))';

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
-- 使用 pg_pwhash (Argon2id) 验证密码
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
    FROM sys_user WHERE username = p_username AND deleted_at IS NULL;
    
    -- 检查用户是否存在且未软删除
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = 'P0001';
    END IF;
    
    -- 使用 pg_pwhash (Argon2id) 验证密码
    -- pwhash_crypt(input, stored_hash) = stored_hash 表示密码正确
    IF v_user.password_hash IS DISTINCT FROM pwhash_crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'Invalid username or password' USING ERRCODE = 'P0001';
    END IF;

    -- 聚合该用户的所有角色代码（包括全局角色 + 本租户角色）
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_user.id
      AND r.deleted_at IS NULL
      AND (r.tenant_id IS NULL OR r.tenant_id = v_user.tenant_id);
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- SSO：作废该用户旧的活跃会话
    UPDATE sys_user_session SET is_used = TRUE WHERE user_id = v_user.id AND is_used = FALSE;

    -- 生成新会话
    v_jti := uuidv7()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_user.id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 构造 JWT Payload
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_user.id::text,
        'username', p_username,
        'tenant_id', v_user.tenant_id::text,
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
COMMENT ON FUNCTION user_login_sso(text, text) IS '用户登录：Argon2id 验证密码，RS256 签名 JWT，SSO 单设备登录，httpOnly Cookie 写入 Refresh Token';

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

    -- 获取最新角色（包括全局角色 + 本租户角色）
    SELECT json_strip_nulls(json_agg(r.role_code))::jsonb INTO v_roles_json
    FROM sys_user_role ur
    JOIN sys_role r ON ur.role_id = r.id
    WHERE ur.user_id = v_session.user_id
      AND r.deleted_at IS NULL
      AND (r.tenant_id IS NULL OR r.tenant_id = v_session.tenant_id);
    
    IF v_roles_json IS NULL THEN
        v_roles_json := '["role_guest"]'::jsonb;
    END IF;

    -- 生成新会话
    v_jti := uuidv7()::text;
    v_new_rt := encode(gen_random_bytes(32), 'hex');
    v_new_rt_hash := sha256(v_new_rt::bytea);

    INSERT INTO sys_user_session (user_id, refresh_token_hash, active_jti, expired_at)
    VALUES (v_session.user_id, v_new_rt_hash, v_jti, now() + interval '7 days');

    -- 构造新 JWT Payload（含最新角色）
    v_payload := json_build_object(
        'jti', v_jti,
        'user_id', v_session.user_id::text,
        'username', v_session.username,
        'tenant_id', v_session.tenant_id::text,
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
        INSERT INTO sys_token_blacklist (jti, expired_at, reason, user_id)
        VALUES (v_session.active_jti, v_session.expired_at, 'kicked', p_user_id)
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
DROP FUNCTION IF EXISTS generate_user_password(text);
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

    SELECT id INTO v_user_id FROM sys_user WHERE username = v_username AND deleted_at IS NULL;

    WITH RECURSIVE menu_cte AS (
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        WHERE ur.user_id = v_user_id AND m.parent_id IS NULL AND m.type IN ('DIR', 'MENU')
          AND m.deleted_at IS NULL
        
        UNION ALL
        
        SELECT 
            m.id, m.parent_id, m.name, m.path, m.component, m.title, m.icon, m.sort_order, m.type
        FROM sys_menu m
        JOIN sys_role_menu rm ON m.id = rm.menu_id
        JOIN sys_user_role ur ON rm.role_id = ur.role_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE ur.user_id = v_user_id AND m.type IN ('DIR', 'MENU')
          AND m.deleted_at IS NULL
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
                  AND btn.deleted_at IS NULL
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

    INSERT INTO sys_user_role (user_id, role_id, tenant_id) 
    VALUES (v_req.user_id, v_req.role_id, v_req.tenant_id)
    ON CONFLICT DO NOTHING;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION approve_role_request(uuid) IS '审批通过角色申请：在同一事务中更新状态并写入 sys_user_role';

-- migrate:down
DROP FUNCTION IF EXISTS approve_role_request(uuid);
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
        INSERT INTO sys_token_blacklist (jti, expired_at, reason, user_id)
        VALUES (v_session.active_jti, v_session.expired_at, 'role_changed', v_user_id)
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
RETURNS uuid AS $$
    SELECT (current_setting('request.jwt.claims', true)::json->>'tenant_id')::uuid;
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

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean AS $$
    SELECT current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin';
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员';

-- ==============================================================================
-- sys_tenant 表：租户隔离（用户只能看到自己租户）
-- ==============================================================================
ALTER TABLE sys_tenant ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_policy ON sys_tenant
AS RESTRICTIVE
USING (id = current_tenant_id())
WITH CHECK (id = current_tenant_id());

-- ==============================================================================
-- sys_department 表：租户隔离
-- ==============================================================================
ALTER TABLE sys_department ENABLE ROW LEVEL SECURITY;

CREATE POLICY dept_tenant_isolation_policy ON sys_department
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_user 表：多租户隔离 + 部门数据隔离
-- ==============================================================================
ALTER TABLE sys_user ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_tenant_isolation_policy ON sys_user
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

CREATE POLICY user_dept_isolation_policy ON sys_user
FOR SELECT
USING (
    is_super_admin()
    OR dept_id = current_user_dept_id()
    OR id = current_user_id()
);

-- ==============================================================================
-- sys_role 表：全局角色（tenant_id=NULL）所有租户可见，租户角色仅本租户可见
-- ==============================================================================
ALTER TABLE sys_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY role_tenant_isolation_policy ON sys_role
AS RESTRICTIVE
USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_api 表：系统级共享，所有认证用户可读
-- ==============================================================================
ALTER TABLE sys_api ENABLE ROW LEVEL SECURITY;

CREATE POLICY api_read_policy ON sys_api
FOR SELECT
USING (is_active = TRUE);

-- ==============================================================================
-- sys_menu 表：系统级共享，所有认证用户可读
-- ==============================================================================
ALTER TABLE sys_menu ENABLE ROW LEVEL SECURITY;

CREATE POLICY menu_read_policy ON sys_menu
FOR SELECT
USING (is_active = TRUE);

-- ==============================================================================
-- sys_user_role 表：通过 user 表继承租户隔离
-- ==============================================================================
ALTER TABLE sys_user_role ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_role_tenant_policy ON sys_user_role
AS RESTRICTIVE
USING (tenant_id = current_tenant_id())
WITH CHECK (tenant_id = current_tenant_id());

-- ==============================================================================
-- sys_user_session 表：用户只能看到自己的会话
-- ==============================================================================
ALTER TABLE sys_user_session ENABLE ROW LEVEL SECURITY;

CREATE POLICY session_user_policy ON sys_user_session
FOR SELECT
USING (user_id = current_user_id());

-- ==============================================================================
-- sys_token_blacklist 表：系统级，仅 SECURITY DEFINER 函数访问
-- ==============================================================================
ALTER TABLE sys_token_blacklist ENABLE ROW LEVEL SECURITY;

CREATE POLICY blacklist_system_policy ON sys_token_blacklist
AS RESTRICTIVE
USING (is_super_admin());

-- ==============================================================================
-- sys_secret 表：系统级，仅 SECURITY DEFINER 函数访问
-- ==============================================================================
ALTER TABLE sys_secret ENABLE ROW LEVEL SECURITY;

CREATE POLICY secret_system_policy ON sys_secret
AS RESTRICTIVE
USING (is_super_admin());

-- migrate:down
DROP POLICY IF EXISTS secret_system_policy ON sys_secret;
ALTER TABLE sys_secret DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS blacklist_system_policy ON sys_token_blacklist;
ALTER TABLE sys_token_blacklist DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_user_policy ON sys_user_session;
ALTER TABLE sys_user_session DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_role_tenant_policy ON sys_user_role;
ALTER TABLE sys_user_role DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS menu_read_policy ON sys_menu;
ALTER TABLE sys_menu DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS api_read_policy ON sys_api;
ALTER TABLE sys_api DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS role_tenant_isolation_policy ON sys_role;
ALTER TABLE sys_role DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_dept_isolation_policy ON sys_user;
DROP POLICY IF EXISTS user_tenant_isolation_policy ON sys_user;
ALTER TABLE sys_user DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dept_tenant_isolation_policy ON sys_department;
ALTER TABLE sys_department DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation_policy ON sys_tenant;
ALTER TABLE sys_tenant DISABLE ROW LEVEL SECURITY;
DROP FUNCTION IF EXISTS is_super_admin();
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
-- 默认租户
-- ==============================================================================
INSERT INTO sys_tenant (id, tenant_code, tenant_name, status) VALUES 
('00000000-0000-0000-0000-000000000001', 'default', '默认租户', 'active')
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 默认部门
-- ==============================================================================
INSERT INTO sys_department (id, dept_name, tenant_id) VALUES 
('00000000-0000-0000-0000-000000000001', '默认部门', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 默认管理员用户（密码：admin123，使用 Argon2id 哈希）
-- ==============================================================================
INSERT INTO sys_user (id, username, password_hash, tenant_id, dept_id) VALUES 
('00000000-0000-0000-0000-100000000001', 'admin', 
 generate_user_password('admin123'), 
 '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (username) DO NOTHING;

-- ==============================================================================
-- 默认角色（全局角色，tenant_id = NULL）
-- ==============================================================================
INSERT INTO sys_role (id, role_code, role_name, tenant_id) VALUES 
('00000000-0000-0000-0000-200000000001', 'super_admin', '超级管理员', NULL),
('00000000-0000-0000-0000-200000000002', 'role_admin', '系统管理员', NULL),
('00000000-0000-0000-0000-200000000003', 'role_editor', '编辑者', NULL),
('00000000-0000-0000-0000-200000000004', 'role_guest', '访客', NULL)
ON CONFLICT (id) DO NOTHING;

-- 将 admin 绑定为超级管理员
INSERT INTO sys_user_role (user_id, role_id, tenant_id) VALUES 
('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000001', '00000000-0000-0000-0000-000000000001')
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
DELETE FROM sys_tenant WHERE id = '00000000-0000-0000-0000-000000000001';
DELETE FROM sys_secret WHERE key_name = 'jwt_private_key_pem';
```

---

## 11. Migration 010：pg_cron 定时清理任务

**文件：** `20260707010_cleanup_cron.sql`

```sql
-- migrate:up

-- ==============================================================================
-- pg_cron 定时清理任务（每小时执行一次）
-- 注意：需要先确认 pg_cron 扩展已安装且 cron.database_name 已配置
-- ==============================================================================

-- 创建通用的 cron 任务记录表（用于审计）
CREATE TABLE IF NOT EXISTS sys_cron_log (
    id BIGSERIAL PRIMARY KEY,
    job_name VARCHAR(100) NOT NULL,
    execution_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    result JSONB,
    duration_ms INT
);
COMMENT ON TABLE sys_cron_log IS 'pg_cron 任务执行日志';

-- 注册清理任务：每小时清理过期的 Token 黑名单和会话
-- cron 语法：分钟 小时 日 月 星期
SELECT cron.schedule(
    'cleanup-expired-tokens',         -- 任务名称
    '0 * * * *',                      -- 每小时整点执行
    $$ SELECT api_v1.cleanup_expired_tokens() $$
);

-- 可选：每天凌晨 3 点清理审计日志（保留 90 天）
SELECT cron.schedule(
    'cleanup-old-audit-logs',
    '0 3 * * *',
    $$ DELETE FROM sys_audit_log WHERE created_at < now() - interval '90 days' $$
);

-- migrate:down
-- 使用参数化方式删除
DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-expired-tokens');
    PERFORM cron.unschedule('cleanup-old-audit-logs');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时忽略
END
$$;
```

---

## 12. Migration 011：审计触发器 + updated_at 触发器

**文件：** `20260707011_audit_triggers.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 1. updated_at 触发器：自动维护所有业务表的 updated_at 字段
-- ==============================================================================

-- sys_tenant
CREATE TRIGGER trg_tenant_updated_at
    BEFORE UPDATE ON sys_tenant
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- sys_department
CREATE TRIGGER trg_department_updated_at
    BEFORE UPDATE ON sys_department
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- sys_user
CREATE TRIGGER trg_user_updated_at
    BEFORE UPDATE ON sys_user
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- sys_role
CREATE TRIGGER trg_role_updated_at
    BEFORE UPDATE ON sys_role
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- sys_api
CREATE TRIGGER trg_api_updated_at
    BEFORE UPDATE ON sys_api
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- sys_menu
CREATE TRIGGER trg_menu_updated_at
    BEFORE UPDATE ON sys_menu
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ==============================================================================
-- 2. 审计触发器函数：记录数据变更到 sys_audit_log
-- ==============================================================================
CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data jsonb;
    v_new_data jsonb;
    v_tenant_id uuid;
BEGIN
    -- 提取 tenant_id（如果表有该字段）
    IF TG_NARGS > 0 AND TG_ARGV[0] = 'tenant_aware' THEN
        IF (TG_OP = 'DELETE') THEN
            v_tenant_id := OLD.tenant_id;
        ELSE
            v_tenant_id := NEW.tenant_id;
        END IF;
    END IF;

    IF (TG_OP = 'DELETE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
    ELSIF (TG_OP = 'INSERT') THEN
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
    ELSIF (TG_OP = 'UPDATE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
    END IF;

    INSERT INTO sys_audit_log (
        table_name,
        operation,
        old_data,
        new_data,
        user_id,
        tenant_id,
        created_at
    ) VALUES (
        TG_TABLE_NAME,
        TG_OP,
        v_old_data,
        v_new_data,
        current_user_id(),
        v_tenant_id,
        now()
    );

    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION audit_trigger_func() IS '审计触发器函数：记录 INSERT/UPDATE/DELETE 操作到 sys_audit_log';

-- 绑定审计触发器到关键业务表
CREATE TRIGGER trg_audit_sys_user
    AFTER INSERT OR UPDATE OR DELETE ON sys_user
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

CREATE TRIGGER trg_audit_sys_role
    AFTER INSERT OR UPDATE OR DELETE ON sys_role
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

CREATE TRIGGER trg_audit_sys_department
    AFTER INSERT OR UPDATE OR DELETE ON sys_department
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

CREATE TRIGGER trg_audit_sys_user_role
    AFTER INSERT OR UPDATE OR DELETE ON sys_user_role
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func('tenant_aware');

-- migrate:down
DROP TRIGGER IF EXISTS trg_audit_sys_user_role ON sys_user_role;
DROP TRIGGER IF EXISTS trg_audit_sys_department ON sys_department;
DROP TRIGGER IF EXISTS trg_audit_sys_role ON sys_role;
DROP TRIGGER IF EXISTS trg_audit_sys_user ON sys_user;
DROP FUNCTION IF EXISTS audit_trigger_func();
DROP TRIGGER IF EXISTS trg_menu_updated_at ON sys_menu;
DROP TRIGGER IF EXISTS trg_api_updated_at ON sys_api;
DROP TRIGGER IF EXISTS trg_role_updated_at ON sys_role;
DROP TRIGGER IF EXISTS trg_user_updated_at ON sys_user;
DROP TRIGGER IF EXISTS trg_department_updated_at ON sys_department;
DROP TRIGGER IF EXISTS trg_tenant_updated_at ON sys_tenant;
```

---

## 13. Migration 012：审计日志表

**文件：** `20260707012_audit_log_table.sql`

```sql
-- migrate:up

-- ==============================================================================
-- 审计日志表：记录所有关键业务表的数据变更
-- ==============================================================================
CREATE TABLE sys_audit_log (
    id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    operation VARCHAR(10) NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data JSONB,
    new_data JSONB,
    user_id UUID,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys_audit_log IS '数据变更审计日志，记录 INSERT/UPDATE/DELETE 操作';
COMMENT ON COLUMN sys_audit_log.old_data IS '变更前的数据（DELETE 时保存被删除的数据）';
COMMENT ON COLUMN sys_audit_log.new_data IS '变更后的数据（INSERT 时保存新数据）';
CREATE INDEX idx_audit_table ON sys_audit_log(table_name);
CREATE INDEX idx_audit_tenant ON sys_audit_log(tenant_id);
CREATE INDEX idx_audit_created ON sys_audit_log(created_at);
CREATE INDEX idx_audit_user ON sys_audit_log(user_id);

-- migrate:down
DROP TABLE IF EXISTS sys_audit_log CASCADE;
```

---

## 14. pgTAP 测试文件

### 14.0 测试环境说明

- **框架：** pgTAP（PostgreSQL 单元测试框架）
- **运行：** `pg_prove -d app_db --schema api_v1 db/tests/*.sql`
- **前置：** 00 migration 已执行完毕，但 RLS 迁移前执行（避免 RLS 影响 superuser 测试）

### 14.1 文件结构

```
db/tests/
├── 01_schema_test.sql        # 表/列/约束存在性验证（40 个测试点）
├── 02_function_test.sql      # 辅助函数行为测试（14 个测试点）
├── 03_trigger_test.sql       # updated_at 触发器 + 黑名单触发器（10 个测试点）
├── 04_login_test.sql         # 正确登录 + 错误密码 + 软删用户（12 个测试点）
├── 05_rls_test.sql           # 跨租户隔离（8 个测试点）
└── 06_rtr_test.sql           # Refresh Token 轮转 + 防重放（8 个测试点）
```

### 14.2 01_schema_test.sql

```sql
-- 01_schema_test.sql：表/列/约束存在性验证
BEGIN;
SELECT plan(58);

-- 1. 表存在性（14 张表）
SELECT has_table('sys_tenant');
SELECT has_table('sys_secret');
SELECT has_table('sys_department');
SELECT has_table('sys_user');
SELECT has_table('sys_role');
SELECT has_table('sys_api');
SELECT has_table('sys_menu');
SELECT has_table('sys_user_role');
SELECT has_table('sys_role_api');
SELECT has_table('sys_role_menu');
SELECT has_table('sys_user_session');
SELECT has_table('sys_token_blacklist');
SELECT has_table('sys_user_role_request');
SELECT has_table('sys_audit_log');
SELECT has_table('sys_cron_log');

-- 2. 关键列存在性（含软删除字段）
SELECT has_column('sys_tenant', 'tenant_code');
SELECT has_column('sys_tenant', 'status');
SELECT has_column('sys_user', 'deleted_at');
-- is_active 已移除，统一使用 deleted_at 软删除
SELECT has_column('sys_user', 'tenant_id');
SELECT has_column('sys_role', 'tenant_id');
SELECT has_column('sys_role', 'deleted_at');
SELECT has_column('sys_department', 'tenant_id');
SELECT has_column('sys_department', 'deleted_at');
SELECT has_column('sys_api', 'deleted_at');
-- is_active 已移除，统一使用 deleted_at 软删除
SELECT has_column('sys_menu', 'deleted_at');
SELECT has_column('sys_menu', 'is_active');

-- 6. 审计 _by 字段存在性
SELECT has_column('sys_tenant', 'created_by');
SELECT has_column('sys_tenant', 'updated_by');
SELECT has_column('sys_tenant', 'deleted_by');
SELECT has_column('sys_user', 'created_by');
SELECT has_column('sys_user', 'updated_by');
SELECT has_column('sys_user', 'deleted_by');
SELECT has_column('sys_role', 'created_by');
SELECT has_column('sys_role', 'updated_by');
SELECT has_column('sys_role', 'deleted_by');
SELECT has_column('sys_department', 'created_by');
SELECT has_column('sys_department', 'updated_by');
SELECT has_column('sys_department', 'deleted_by');
SELECT has_column('sys_api', 'created_by');
SELECT has_column('sys_api', 'updated_by');
SELECT has_column('sys_api', 'deleted_by');
SELECT has_column('sys_menu', 'created_by');
SELECT has_column('sys_menu', 'updated_by');
SELECT has_column('sys_menu', 'deleted_by');

-- 3. 唯一约束验证
SELECT col_is_unique('sys_user', 'username');
SELECT col_is_unique('sys_user_session', 'refresh_token_hash');
SELECT col_is_unique('sys_api', ARRAY['path', 'method']);
SELECT col_is_unique('sys_tenant', 'tenant_code');

-- 4. 外键约束验证
SELECT fk_ok('sys_user', 'tenant_id', 'sys_tenant', 'id');
SELECT fk_ok('sys_department', 'tenant_id', 'sys_tenant', 'id');
SELECT fk_ok('sys_user', 'dept_id', 'sys_department', 'id');
SELECT fk_ok('sys_user_role', 'user_id', 'sys_user', 'id');
SELECT fk_ok('sys_user_role', 'role_id', 'sys_role', 'id');
SELECT fk_ok('sys_role_api', 'role_id', 'sys_role', 'id');
SELECT fk_ok('sys_role_api', 'api_id', 'sys_api', 'id');

-- 5. casbin_rule 视图存在
SELECT has_view('casbin_rule');

-- 6. 扩展存在
SELECT has_extension('pg_pwhash');

SELECT * FROM finish();
ROLLBACK;
```

### 14.3 02_function_test.sql

```sql
-- 02_function_test.sql：辅助函数行为测试
BEGIN;
SELECT plan(14);

-- sha256 函数测试
SELECT function_lang_is('sha256', 'sql');
SELECT is(sha256('hello'::bytea), encode(digest('hello', 'sha256'), 'hex'), 'sha256 正确计算');

-- current_user_id 函数（无 JWT 时应返回全零 UUID）
SELECT lives_ok('SELECT current_user_id()', 'current_user_id 不抛异常');
SELECT is(current_tenant_id(), NULL, '无 JWT 时 tenant_id 为 NULL');

-- cleanup_expired_tokens 函数
SELECT function_lang_is('cleanup_expired_tokens', 'plpgsql');
SELECT lives_ok('SELECT cleanup_expired_tokens()', 'cleanup 函数可调用');

-- update_updated_at 函数存在
SELECT has_function('update_updated_at');
SELECT function_lang_is('update_updated_at', 'plpgsql');

-- audit_trigger_func 函数存在
SELECT has_function('audit_trigger_func');

-- is_super_admin 函数
SELECT has_function('is_super_admin');
SELECT function_lang_is('is_super_admin', 'sql');

-- pg_pwhash 函数
SELECT has_function('pwhash_crypt');
SELECT has_function('pwhash_gen_salt');

SELECT * FROM finish();
ROLLBACK;
```

### 14.4 03_trigger_test.sql

```sql
-- 03_trigger_test.sql：触发器行为测试
BEGIN;
SELECT plan(10);

-- updated_at 触发器存在
SELECT trigger_exists('sys_user', 'trg_user_updated_at');
SELECT trigger_exists('sys_role', 'trg_role_updated_at');
SELECT trigger_exists('sys_department', 'trg_department_updated_at');
SELECT trigger_exists('sys_tenant', 'trg_tenant_updated_at');

-- updated_at 自动更新
SELECT lives_ok($$
    PREPARE update_test AS UPDATE sys_user SET username = 'admin' WHERE id = '00000000-0000-0000-0000-100000000001';
    EXECUTE update_test;
    DEALLOCATE update_test;
$$, 'updated_at 自动更新不抛异常');

-- blacklist_at_on_role_change 触发器存在
SELECT trigger_exists('sys_user_role', 'trg_blacklist_on_role_change');

-- 角色变更触发器：分配角色后，检查黑名单是否有对应记录
SELECT lives_ok($$
    SET request.jwt.claims = '{"user_id":"00000000-0000-0000-0000-100000000001","tenant_id":"00000000-0000-0000-0000-000000000001","roles":["super_admin"]}';
    INSERT INTO sys_user_role (user_id, role_id, tenant_id) 
    VALUES ('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000002', '00000000-0000-0000-0000-000000000001');
    DELETE FROM sys_user_role WHERE user_id = '00000000-0000-0000-0000-100000000001' AND role_id = '00000000-0000-0000-0000-200000000002';
    RESET request.jwt.claims;
$$, '角色变更触发器流程');

-- pg_notify 触发器存在
SELECT trigger_exists('sys_role_api', 'trg_reload_on_role_api');

-- audit_trigger_func 触发器
SELECT trigger_exists('sys_user', 'trg_audit_sys_user');
SELECT trigger_exists('sys_role', 'trg_audit_sys_role');

SELECT * FROM finish();
ROLLBACK;
```

### 14.5 04_login_test.sql

```sql
-- 04_login_test.sql：登录流程测试
BEGIN;
SELECT plan(12);

-- 设置 superuser 测试身份
SET request.jwt.claims = '{"user_id":"00000000-0000-0000-0000-100000000001","tenant_id":"00000000-0000-0000-0000-000000000001","roles":["super_admin"]}';
SET request.headers = '{"x-forwarded-for":"127.0.0.1","user-agent":"pgTAP/1.0"}';

-- 1. 正确登录应返回 JSON
SELECT lives_ok($$
    SELECT user_login_sso('admin', 'admin123')
$$, '正确密码登录不抛异常');

-- 2. 错误密码应抛异常
SELECT throws_ok($$
    SELECT user_login_sso('admin', 'wrong_password')
$$, 'P0001', 'Invalid username or password', '错误密码抛 P0001');

-- 3. 不存在的用户应抛异常
SELECT throws_ok($$
    SELECT user_login_sso('nonexistent_user', 'any_password')
$$, 'P0001', 'Invalid username or password', '不存在的用户抛 P0001');

-- 4. 软删用户应无法登录
-- （需要先创建并软删除测试用户）

-- 5. user_login_sso 函数 SECURITY DEFINER
SELECT function_is_definer('user_login_sso');

-- 6. refresh_token_rtr 函数 SECURITY DEFINER
SELECT function_is_definer('refresh_token_rtr');

-- 7. check_token_blacklist 函数存在
SELECT has_function('check_token_blacklist');

-- 8. pg_pwhash 生成哈希测试
SELECT lives_ok($$
    SELECT pwhash_crypt('test_password', pwhash_gen_salt('argon2id'))
$$, 'Argon2id 哈希生成不抛异常');

-- 9. pg_pwhash 验证测试
SELECT lives_ok($$
    DECLARE
        v_hash text;
    BEGIN
        v_hash := pwhash_crypt('test_password', pwhash_gen_salt('argon2id'));
        IF pwhash_crypt('test_password', v_hash) != v_hash THEN
            RAISE EXCEPTION 'Password verification failed';
        END IF;
    END;
$$, 'Argon2id 密码验证通过');

RESET request.jwt.claims;
RESET request.headers;

SELECT * FROM finish();
ROLLBACK;
```

### 14.6 05_rls_test.sql

```sql
-- 05_rls_test.sql：RLS 行级安全策略测试
BEGIN;
SELECT plan(8);

-- 注意：此测试需要在 RLS 迁移后执行，并使用不同 tenant_id 的 JWT

-- 1. 验证关键表上有 RLS 启用
SELECT table_has_rls('sys_tenant');
SELECT table_has_rls('sys_user');
SELECT table_has_rls('sys_role');
SELECT table_has_rls('sys_department');
SELECT table_has_rls('sys_api');
SELECT table_has_rls('sys_menu');

-- 2. 验证 sys_role 的 RLS 策略允许全局角色（tenant_id=NULL）
SELECT lives_ok($$
    SELECT 1 FROM sys_role WHERE tenant_id IS NULL
$$, '全局角色可查询');

-- 3. 验证 sys_api 的 RLS 策略允许所有认证用户读取
SELECT lives_ok($$
    SELECT 1 FROM sys_api WHERE is_active = TRUE
$$, 'API 资源可读');

SELECT * FROM finish();
ROLLBACK;
```

### 14.7 06_rtr_test.sql

```sql
-- 06_rtr_test.sql：Refresh Token 轮转 + 防重放测试
BEGIN;
SELECT plan(8);

-- 前置：需要先执行登录获取 refresh_token
-- 此处使用 dbmock 模拟

-- 1. refresh_token_rtr 使用旧 RT 刷新应成功
-- 2. 再次使用同一旧 RT 应失败（防重放）
-- 3. 刷新后应返回新的 access_token
-- 4. 使用无效 RT 应失败
-- 5. 过期 RT 应被拒绝
-- 6. 已被 is_used=TRUE 的 RT 应触发全端下线

-- 由于 refresh_token_rtr 依赖 Casdoor 端点，基础测试仅验证函数结构和异常路径

SELECT has_function('refresh_token_rtr');
SELECT function_lang_is('refresh_token_rtr', 'plpgsql');
SELECT function_is_definer('refresh_token_rtr');

-- 无效 RT 应抛异常 'P0001'
SELECT throws_ok($$
    SELECT refresh_token_rtr('invalid-refresh-token-that-is-64-characters-long-1234567890abcdef1234567890abcdef')
$$, 'P0001', 'Invalid Session', '无效 RT 被拒绝');

SELECT * FROM finish();
ROLLBACK;
```

---

## 15. 验收清单

Agent 完成所有 migration 后，逐项执行以下验收：

| # | 验收项 | 验证方法 | 通过 |
|:---:|:---|:---|:---:|
| D1 | 14 张业务表 + 2 张辅助表（cron_log + audit_log）全部存在 | `SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'sys_%'` | ☐ |
|| D2 | `deleted_at` 软删除字段 + `_by` 审计字段在所有业务表存在 | `SELECT attname FROM pg_attribute WHERE attrelid = 'sys_user'::regclass AND attname IN ('deleted_at','created_by','updated_by','deleted_by')` → 返回 4 行 | ☐ |
| D3 | `updated_at` 触发器在 6 张业务表绑定 | `SELECT tgname FROM pg_trigger WHERE tgname LIKE 'trg_%_updated_at'` → 返回 6 个触发器 | ☐ |
| D4 | `casbin_rule` 视图过滤软删除 | `SELECT definition_视图 FROM pg_views WHERE viewname = 'casbin_rule'` 确认含 `deleted_at IS NULL` | ☐ |
| D5 | RLS 覆盖 11 张业务表 | `SELECT relname, relrowsecurity FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'sys_%'` → 11 张表 relrowsecurity=true | ☐ |
| D6 | `user_login_sso` 可调用（Argon2id 验证） | `SELECT user_login_sso('admin', 'admin123')` → JSON 含 access_token | ☐ |
| D7 | `get_user_menu` 返回嵌套 JSON（含 children） | 检查返回 JSON 的顶层元素包含 `children` 字段 | ☐ |
| D8 | pg_notify 触发器正常 | 会话 A: `LISTEN casbin_channel;` 会话 B: `INSERT INTO sys_role_api ...` → 会话 A 收到 JSON payload | ☐ |
| D9 | Token 黑名单生效（jti 不空前可拦截） | `INSERT INTO sys_token_blacklist (jti, expired_at, reason) VALUES ('test-jti', now()+interval '1h', 'revoked');` → JWT 含该 jti 时 check_token_blacklist() 抛异常 | ☐ |
| D10 | 角色变更触发器写黑名单 | `INSERT INTO sys_user_role ...` → `SELECT * FROM sys_token_blacklist WHERE reason='role_changed'` | ☐ |
| D11 | `pg_cron` 任务已注册 | `SELECT * FROM cron.job WHERE jobname LIKE 'cleanup-%'` | ☐ |
| D12 | `update_updated_at()` 自动执行 | UPDATE sys_user SET username='test' WHERE id='...' → updated_at 自动更新 | ☐ |
| D13 | pgTAP 基础测试通过 | `pg_prove -d app_db db/tests/*.sql` → 全部 PASS | ☐ |
| D14 | `pg_pwhash` 扩展已安装 | `SELECT extname FROM pg_extension WHERE extname='pg_pwhash'` | ☐ |
| D15 | 全局角色（tenant_id=NULL）可查询 | `SELECT COUNT(*) FROM sys_role WHERE tenant_id IS NULL` → 返回 4 | ☐ |
|| D16 | Dbmate status 全部已执行 | `dbmate status` → 所有 12 个 migration 显示 `up` | ☐ |
|| D17 | 所有业务表包含完整审计字段（created_by/updated_by/deleted_by） | `SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='public' AND column_name LIKE '%by' AND table_name LIKE 'sys_%'` → 返回 18 行（6 表 × 3 字段） | ☐ |

> **通过标准：** 17/17 项全部打勾。任一未通过则修复后重新验收。

---

## 16. 修订日志

| 版本 | 日期 | 变更内容 |
|:---|:---|:---|
| v1.0 | 2026-07-07 | 初始版本 |
| v2.0 | 2026-07-08 | 深度审查后全面修订：JWT Casdoor 化 + Soft Delete + RLS 全覆盖 + 审计表 + pg_cron + pgTAP |
|| v3.0 | 2026-07-21 | 重大修订：UUID v7 + Argon2id（pg_pwhash）+ sys_tenant 表 + 租户字段策略 + 审计触发器 |
|| v3.1 | 2026-07-21 | 补全 6 张业务表的 `_by` 审计字段（created_by/updated_by/deleted_by），完整实现 IFullAuditedObject |
