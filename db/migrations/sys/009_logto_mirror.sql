-- ==============================================================================
-- Migration 009: Logto 镜像表 + 自主授权表（Phase 2 — Casdoor → Logto 切换）
-- ------------------------------------------------------------------------------
-- 背景: Logto 替代 Casdoor 作为认证/组织/角色目录托管方（05 方案 D1/D2 v2.0 变体 B）
-- 决策: 租户/用户主键 text 化 = Logto id（21 位 nanoid，D17/D18）；N4 空白业务全新设计
-- 幂等: 全部 IF NOT EXISTS / ON CONFLICT DO NOTHING —— apply-src.sh 重复执行无害
-- 引用: 05-Logto认证与权限架构-完善版.md §6、06-开发路线 §3 T4
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- §1 镜像表（Logto 权威 → PG 只读投影，不进授权判定路径）
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 1.1 users — Logto 用户镜像（05 F2 白名单字段）
--     id = Logto 用户 id（21 位 nanoid 字符串，非 UUID）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id              text PRIMARY KEY,                          -- Logto 用户 id（nanoid 21）
    username        varchar(128) NOT NULL DEFAULT '',          -- Logto username
    primary_email   varchar(255) NOT NULL DEFAULT '',          -- Logto primaryEmail
    primary_phone   varchar(32)  NOT NULL DEFAULT '',          -- Logto primaryPhone
    name            varchar(255) NOT NULL DEFAULT '',          -- Logto name（显示名）
    avatar          varchar(500) NOT NULL DEFAULT '',          -- Logto avatar URL
    custom_data     jsonb        NOT NULL DEFAULT '{}',        -- Logto customData
    identities      jsonb        NOT NULL DEFAULT '{}',        -- Logto identities（第三方身份）
    last_sign_in_at timestamptz,                               -- Logto lastSignInAt
    is_suspended    boolean      NOT NULL DEFAULT false,       -- Logto isSuspended
    application_id  varchar(64)  NOT NULL DEFAULT '',          -- Logto applicationId
    created_at      timestamptz  NOT NULL DEFAULT now(),       -- Logto User.createdAt（webhook 提供；本地兜底）
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    created_by      text,
    updated_by      text,
    deleted_by      text
);

COMMENT ON TABLE users IS 'Logto 用户镜像表（Logto 权威，PG 只读；不进授权判定路径）';
COMMENT ON COLUMN users.id IS 'Logto 用户 id（21 位 nanoid 字符串，与服务端 JWT sub 一致）';
COMMENT ON COLUMN users.primary_email IS 'Logto primaryEmail — 用户主邮箱';
COMMENT ON COLUMN users.primary_phone IS 'Logto primaryPhone — 用户主电话';

CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_primary_email ON users(primary_email);
CREATE INDEX IF NOT EXISTS idx_users_is_suspended ON users(is_suspended);

-- ---------------------------------------------------------------------------
-- 1.2 tenants — Logto 组织镜像（租户容器）
--     id = Logto organization id（21 位 nanoid，D17）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
    id              text PRIMARY KEY,                          -- Logto organization id
    name            varchar(255) NOT NULL DEFAULT '',          -- Logto organization name
    description     text         NOT NULL DEFAULT '',          -- Logto organization description
    custom_data     jsonb        NOT NULL DEFAULT '{}',        -- Logto organization customData
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    created_by      text,
    updated_by      text,
    deleted_by      text
);

COMMENT ON TABLE tenants IS 'Logto 组织镜像表（租户容器；id = Logto organization id，与业务 tenant_id 同键）';
COMMENT ON COLUMN tenants.id IS 'Logto organization id（21 位 nanoid）—— 业务表 tenant_id 的直接 FK 目标';

CREATE INDEX IF NOT EXISTS idx_tenants_name ON tenants(name);

-- ---------------------------------------------------------------------------
-- 1.3 user_tenants — 组织成员关系镜像
--     来源: Organization.Membership.Updated webhook（增量 addedUserIds/removedUserIds）
--     复合 PK 保证唯一 + 幂等删除
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_tenants (
    organization_id text NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, user_id)
);

COMMENT ON TABLE user_tenants IS 'Logto 组织成员关系镜像（来源: Organization.Membership.Updated webhook）';

CREATE INDEX IF NOT EXISTS idx_ut_org ON user_tenants(organization_id);
CREATE INDEX IF NOT EXISTS idx_ut_user ON user_tenants(user_id);

-- ---------------------------------------------------------------------------
-- 1.4 iam_role — Logto 角色目录镜像
--     role_code = 生成列（GENERATED ALWAYS AS name），与 iam_role_api.role_code 对齐（E5）
--     来源: Role.Created / Role.Data.Updated / Role.Deleted webhook
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_role (
    id              text PRIMARY KEY,                          -- Logto 角色 id
    name            varchar(128) NOT NULL,                     -- Logto 角色名（全局唯一，F20）
    role_code       text GENERATED ALWAYS AS (name) STORED,    -- 生成列 = name（E5），join key
    type            varchar(32)  NOT NULL DEFAULT 'User',      -- Logto 角色类型: User / MachineToMachine
    is_default      boolean      NOT NULL DEFAULT false,       -- Logto 是否默认角色
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE iam_role IS 'Logto 角色目录镜像（只读投影；授权判定不读此表，读 claims roles）';
COMMENT ON COLUMN iam_role.role_code IS '生成列 = name（E5），与 iam_role_api.role_code / 网关 required_roles 对齐';

CREATE UNIQUE INDEX IF NOT EXISTS idx_iam_role_name ON iam_role(name);
CREATE INDEX IF NOT EXISTS idx_iam_role_type ON iam_role(type);

-- ---------------------------------------------------------------------------
-- 1.5 iam_user_role — 用户↔角色分配镜像（P1 启用）
--     来源: JIT 覆盖 + 管理操作主动同步 + 每日对账（05 §6.5）
--     P0 阶段可不建此表（授权判定不依赖），按管理端报表需求按需启用
--     此表为占位 DDL（不含索引，按需重建）
-- ---------------------------------------------------------------------------
-- CREATE TABLE IF NOT EXISTS iam_user_role (
--     user_id   text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
--     role_id   text NOT NULL REFERENCES iam_role(id) ON DELETE CASCADE,
--     PRIMARY KEY (user_id, role_id)
-- );

-- ==============================================================================
-- §2 自主表（PG 业务真相源，全新建 N4；授权判定核心数据）
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 2.1 iam_api — API 权限点目录
--     数据来源: 现有 sys_api 数据迁移（API 目录属业务自主数据，非 Casdoor 资产）
--     id 保留 UUID v7（内部分配，不依赖外部 IdP）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_api (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    path            varchar(200) NOT NULL,                      -- API 路径模式（如 /rpc/get_*）
    method          varchar(20)  NOT NULL DEFAULT '*',          -- HTTP 方法（GET/POST/PUT/DELETE/*）
    name            varchar(100) NOT NULL,                      -- 权限点中文名
    description     varchar(255),
    is_active       boolean      NOT NULL DEFAULT true,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    created_by      text,
    updated_by      text
);

COMMENT ON TABLE iam_api IS 'API 权限点目录（PG 自主数据）；role_code 经 iam_role_api 绑定角色';
COMMENT ON COLUMN iam_api.path IS 'API 路径模式，与 PostgREST 暴露的 RPC/视图对应';
COMMENT ON COLUMN iam_api.method IS 'HTTP 方法；* 表示所有方法';

CREATE UNIQUE INDEX IF NOT EXISTS idx_iam_api_path_method ON iam_api(path, method);

-- ---------------------------------------------------------------------------
-- 2.2 iam_menu — 菜单树
--     数据来源: 现有 sys_menu 数据迁移
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_menu (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    parent_id       uuid REFERENCES iam_menu(id) ON DELETE SET NULL,
    menu_name       varchar(100) NOT NULL,
    path            varchar(200),
    icon            varchar(100),
    order_num       integer      NOT NULL DEFAULT 0,
    is_active       boolean      NOT NULL DEFAULT true,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    created_by      text,
    updated_by      text
);

COMMENT ON TABLE iam_menu IS '菜单树（PG 自主数据）；role_code 经 iam_role_menu 绑定角色';

CREATE INDEX IF NOT EXISTS idx_iam_menu_parent ON iam_menu(parent_id);

-- ---------------------------------------------------------------------------
-- 2.3 iam_role_api — 角色→API 权限绑定
--     role_code = Logto 角色名（字符串），与 JWT roles claim / PG 角色名统一（D19 R1）
--     join key 由 F20 唯一性保证
--     规模: 角色×API ≤ 5 万行（与用户数无关）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_role_api (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    role_code       text NOT NULL,                              -- Logto 角色名（唯一 join key）
    api_id          uuid NOT NULL REFERENCES iam_api(id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text,
    UNIQUE (role_code, api_id)
);

COMMENT ON TABLE iam_role_api IS '角色→API 权限绑定（PG 自主数据）；role_code = Logto 角色名（claims roles 数组元素）';
COMMENT ON COLUMN iam_role_api.role_code IS 'Logto 角色名（字符串，F20 单实例全局唯一），与 JWT roles claim 对齐';

CREATE INDEX IF NOT EXISTS idx_iam_role_api_role ON iam_role_api(role_code);
CREATE INDEX IF NOT EXISTS idx_iam_role_api_api ON iam_role_api(api_id);

-- ---------------------------------------------------------------------------
-- 2.4 iam_role_menu — 角色→菜单绑定
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iam_role_menu (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    role_code       text NOT NULL,
    menu_id         uuid NOT NULL REFERENCES iam_menu(id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text,
    UNIQUE (role_code, menu_id)
);

COMMENT ON TABLE iam_role_menu IS '角色→菜单绑定（PG 自主数据）';

CREATE INDEX IF NOT EXISTS idx_iam_role_menu_role ON iam_role_menu(role_code);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_menu ON iam_role_menu(menu_id);

-- ==============================================================================
-- §3 RLS helper 重写（Logto 语义：roles 为字符串数组，05 §5.3.1）
--    Casdoor 旧 helper 为对象数组版本（e->>'name' + isEnabled），需替换
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 3.1 current_user_roles() — 从 Logto JWT roles claim 提取角色名数组
--     Logto: roles = ["role_super_admin", "tenant_admin", ...]（字符串数组）
--     Casdoor: roles = [{name: "super_admin", isEnabled: true, ...}]（对象数组）
--     本版本: jsonb_array_elements_text — 直接拿字符串，无 isEnabled 概念
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_roles() RETURNS text[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(current_setting('request.jwt.claims', true)::jsonb -> 'roles', '[]'::jsonb)
        )
    ), ARRAY[]::text[])
$$;

COMMENT ON FUNCTION current_user_roles() IS '当前用户 Logto 角色名数组（JWT roles claim，字符串数组，零查询）';

-- ---------------------------------------------------------------------------
-- 3.2 current_tenant_id() — 从 organization_id claim 提取（保留设计，不变）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb ->> 'organization_id', '')
$$;

COMMENT ON FUNCTION current_tenant_id() IS '当前租户 ID = Logto organization_id claim（零查询）';

-- ---------------------------------------------------------------------------
-- 3.3 current_user_id() — 从 sub claim 提取（Logto user id = 21 位 nanoid）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_id() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')
$$;

COMMENT ON FUNCTION current_user_id() IS '当前用户 ID = Logto sub claim（21 位 nanoid 字符串）';

-- ---------------------------------------------------------------------------
-- 3.4 is_super_admin() — 检查是否含全局超管角色
--     Logto 角色名 = role_super_admin（全局角色，05 §6.2）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT current_user_roles() @> ARRAY['role_super_admin']
$$;

COMMENT ON FUNCTION is_super_admin() IS '当前用户是否含 role_super_admin 角色（读 claims，零查询）';

-- ==============================================================================
-- §4 兼容视图重建
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 4.1 public.sys_user 兼容视图 — 新版：users + sys_user_profile 投影
--     沿用 security_invoker 语义；列结构与旧版对齐（username/email/phone/is_active/tenant_id）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.sys_user
WITH (security_invoker = true) AS
SELECT
    u.id,
    u.username,
    NULL::text AS password_hash,              -- 密码由 Logto 管理，不再暴露
    p.tenant_id,
    p.dept_id,
    u.primary_email  AS email,
    u.primary_phone  AS phone,
    NOT u.is_suspended AS is_active,          -- D17: is_active = NOT isSuspended
    u.created_at,
    u.updated_at,
    u.deleted_at,
    u.created_by,
    u.updated_by,
    u.deleted_by
FROM users u
LEFT JOIN sys_user_profile p ON p.user_id = u.id;

COMMENT ON VIEW public.sys_user IS 'Logto 用户兼容视图（替代 Casdoor 版 casdoor_user_mirror 投影）；security_invoker=true';

-- ---------------------------------------------------------------------------
-- 4.2 casbin_rule 视图 — 重建为 iam_role_api + iam_role_menu 投影（E3）
--     沿用 v0/v1/v2 结构；role_code 对齐 Logto 角色名
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW casbin_rule AS
-- p 规则：角色→API 绑定
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    ra.role_code::varchar AS v0,              -- 角色名（Logto 角色名 = role_code）
    a.path::varchar AS v1,                    -- API 路径
    a.method::varchar AS v2,                  -- HTTP 方法
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_api ra
JOIN iam_api a ON ra.api_id = a.id
WHERE a.is_active = true
UNION ALL
-- p 规则：角色→菜单绑定（前端消费）
SELECT
    NULL::integer,
    'p'::varchar,
    rm.role_code::varchar AS v0,
    m.path::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar,
    NULL::varchar,
    NULL::varchar
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active = true;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图 — Logto 版：iam_role_api + iam_role_menu 投影（E3）；v0=role_code, v1=资源, v2=action';

-- ==============================================================================
-- §5 权限授予
-- ==============================================================================

-- 镜像表只读（web_anon 不可读，仅 authenticated）
GRANT SELECT ON users TO authenticated;
GRANT SELECT ON tenants TO authenticated;
GRANT SELECT ON user_tenants TO authenticated;
GRANT SELECT ON iam_role TO authenticated;

-- 自主表：CRUD 权限交管理端 RPC（带 has_permission 检查），authenticated 可读
GRANT SELECT ON iam_api TO authenticated;
GRANT SELECT ON iam_menu TO authenticated;
GRANT SELECT ON iam_role_api TO authenticated;
GRANT SELECT ON iam_role_menu TO authenticated;

-- 兼容视图
GRANT SELECT ON public.sys_user TO authenticated;
GRANT SELECT ON casbin_rule TO authenticated;

-- ==============================================================================
-- migrate:down
-- ==============================================================================
-- 注意: down 需按依赖顺序删除（FK → 表 → 函数/视图）
-- 回滚到 Casdoor 版本需重跑 007 迁移 + apply-src

DROP VIEW IF EXISTS public.sys_user CASCADE;
DROP VIEW IF EXISTS casbin_rule CASCADE;
DROP TABLE IF EXISTS iam_user_role CASCADE;
DROP TABLE IF EXISTS iam_role_menu CASCADE;
DROP TABLE IF EXISTS iam_role_api CASCADE;
DROP TABLE IF EXISTS iam_menu CASCADE;
DROP TABLE IF EXISTS iam_api CASCADE;
DROP TABLE IF EXISTS iam_role CASCADE;
DROP TABLE IF EXISTS user_tenants CASCADE;
DROP TABLE IF EXISTS tenants CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- RLS helper 恢复 Casdoor 版（对象数组版）由 apply-src 重跑 db/src/sys/functions/current_user_roles.sql
-- 本迁移仅 down 时不恢复旧函数签名；完整回滚需配套执行 db/src 目录 apply-src
