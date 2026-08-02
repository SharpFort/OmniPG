-- ==============================================================================
-- Migration 007: Casdoor 用户镜像表（casdoor_user_mirror）+ 业务档案表（sys_user_profile）
-- ------------------------------------------------------------------------------
-- 背景: Phase 1（Casdoor 全量替代本地身份存储，D1-D9 决策落地）
--   - casdoor_user_mirror: Casdoor user 表全量镜像（69 个字段，小写列名 = Casdoor
--     字段名小写，保证 Database Syncer 全量写回 map 可直接落列）
--   - 派生列 is_active/deleted_at: D6 状态映射（IsForbidden/IsDeleted → 业务状态）
--   - sys_user_profile: 业务档案表（租户/部门归属 + 扩展字段），1:1 关联镜像表
--   - public.sys_user: 兼容视图（security_invoker=true），列结构与旧表一致，
--     保证既有读路径函数/视图/RPC 无需改动;旧表数据备份至 sys_user_legacy
-- 幂等性: 本迁移会被 apply-src.sh 重复执行，全部使用 IF EXISTS/IF NOT EXISTS
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 0. 存量库对齐（既有技术债修复：库结构与迁移文件不同步的历史遗留，幂等）
-- ==============================================================================
-- 0.0 业务 DB 角色补建（init/02-schemas.sql 定义但从未执行的库；幂等）
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'super_admin') THEN
        CREATE ROLE super_admin NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_admin') THEN
        CREATE ROLE role_admin NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_editor') THEN
        CREATE ROLE role_editor NOLOGIN NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'role_guest') THEN
        CREATE ROLE role_guest NOLOGIN NOINHERIT;
    END IF;
END $$;
-- 业务角色授予 authenticator（允许 PostgREST SET ROLE 切换；init/02-schemas.sql 模式）
GRANT super_admin TO authenticator;
GRANT role_admin TO authenticator;
GRANT role_editor TO authenticator;
GRANT role_guest TO authenticator;
-- 注意: GRANT authenticated/web_anon TO authenticator 需 superuser（app_owner 无 ADMIN），
--       由 init/02-schemas.sql 或 DBA 以 postgres 执行（本迁移不做，避免幂等失败）

-- 0.1 sys_audit_log 列名对齐（旧结构 old_values/new_values → 005 文件结构 old_data/new_data）
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'sys_audit_log' AND column_name = 'old_values')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'sys_audit_log' AND column_name = 'old_data') THEN
        ALTER TABLE sys_audit_log RENAME COLUMN old_values TO old_data;
        ALTER TABLE sys_audit_log RENAME COLUMN new_values TO new_data;
    END IF;
END $$;

-- 0.2 sys_config 表补建（006 迁移从未应用的库；幂等）
CREATE TABLE IF NOT EXISTS sys_config (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    config_key VARCHAR(100) NOT NULL UNIQUE,
    config_value TEXT,
    config_type VARCHAR(20) NOT NULL DEFAULT 'string',
    description VARCHAR(255),
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_config_key ON sys_config(config_key);
CREATE INDEX IF NOT EXISTS idx_config_public ON sys_config(is_public) WHERE is_public = TRUE;
INSERT INTO sys_config (config_key, config_value, config_type, description, is_public) VALUES
('site.title', '零后端权限管理系统', 'string', '站点标题', TRUE),
('site.logo', '/logo.png', 'string', '站点 Logo URL', TRUE),
('site.copyright', '© 2026 OmniPG', 'string', '页脚版权信息', TRUE),
('password.min_length', '8', 'number', '密码最小长度', FALSE),
('password.require_uppercase', 'true', 'boolean', '需要大写字母', FALSE),
('password.require_number', 'true', 'boolean', '需要数字', FALSE),
('password.require_special', 'false', 'boolean', '需要特殊字符', FALSE),
('password.max_age_days', '0', 'number', '密码有效期（0=永不过期）', FALSE),
('password.history_count', '0', 'number', '密码历史记录数（0=不限制）', FALSE),
('session.timeout_minutes', '15', 'number', 'Access Token 有效期（分钟）', FALSE),
('session.max_concurrent', '1', 'number', '单用户最大并发会话数', FALSE),
('security.login_attempts_limit', '5', 'number', '登录失败锁定阈值', FALSE),
('security.lockout_duration_minutes', '30', 'number', '登录锁定时长（分钟）', FALSE)
ON CONFLICT (config_key) DO NOTHING;

-- ==============================================================================
-- 1. casdoor_user_mirror 镜像表（69 个 Casdoor 用户字段 + 派生列 + 审计列）
--    列名 = Casdoor 字段名小写（Database Syncer 写回 map 以 Casdoor 字段名为列名，
--    PG 未加引号标识符小写化，故镜像表列名必须为小写连写形式）
--    类型: 全 varchar/text（syncer 写入值为字符串，避免类型转换失败）;
--          id 为 uuid（Casdoor 用户 Id 是 UUID，与 JWT sub 直接匹配）
-- ==============================================================================
CREATE TABLE IF NOT EXISTS casdoor_user_mirror (
    -- 身份主键（Casdoor 用户 Id，JWT sub）
    id                    uuid PRIMARY KEY,

    -- ===== Casdoor 用户字段（69 个，全量镜像）=====
    name                  varchar(100) NOT NULL DEFAULT '',   -- 用户名（登录名）
    createdtime           varchar(40)  NOT NULL DEFAULT '',
    updatedtime           varchar(40)  NOT NULL DEFAULT '',
    deletedtime           varchar(40)  NOT NULL DEFAULT '',
    type                  varchar(100) NOT NULL DEFAULT '',
    password              text         NOT NULL DEFAULT '',   -- Casdoor 哈希，仅存档，禁止用于业务验证
    passwordsalt          varchar(100) NOT NULL DEFAULT '',
    displayname           varchar(100) NOT NULL DEFAULT '',
    avatar                varchar(500) NOT NULL DEFAULT '',
    permanentavatar       varchar(500) NOT NULL DEFAULT '',
    email                 varchar(100) NOT NULL DEFAULT '',
    phone                 varchar(100) NOT NULL DEFAULT '',
    location              varchar(100) NOT NULL DEFAULT '',
    address               text         NOT NULL DEFAULT '',
    affiliation           varchar(100) NOT NULL DEFAULT '',
    title                 varchar(100) NOT NULL DEFAULT '',
    idcardtype            varchar(100) NOT NULL DEFAULT '',
    idcard                varchar(100) NOT NULL DEFAULT '',
    homepage              varchar(100) NOT NULL DEFAULT '',
    bio                   varchar(100) NOT NULL DEFAULT '',
    tag                   varchar(100) NOT NULL DEFAULT '',
    region                varchar(100) NOT NULL DEFAULT '',
    language              varchar(100) NOT NULL DEFAULT '',
    gender                varchar(100) NOT NULL DEFAULT '',
    birthday              varchar(100) NOT NULL DEFAULT '',
    education             varchar(100) NOT NULL DEFAULT '',
    score                 varchar(20)  NOT NULL DEFAULT '0',
    ranking               varchar(20)  NOT NULL DEFAULT '0',
    isdefaultavatar       varchar(10)  NOT NULL DEFAULT 'false',
    isonline              varchar(10)  NOT NULL DEFAULT 'false',
    isadmin               varchar(10)  NOT NULL DEFAULT 'false',
    isforbidden           varchar(10)  NOT NULL DEFAULT 'false',  -- D6: 禁用标志（'true'/'false'）
    isdeleted             varchar(10)  NOT NULL DEFAULT 'false',  -- D6: 删除标志（'true'/'false'）
    createdip             varchar(100) NOT NULL DEFAULT '',
    preferredmfatype      varchar(100) NOT NULL DEFAULT '',
    totpsecret            text         NOT NULL DEFAULT '',
    signupapplication     varchar(100) NOT NULL DEFAULT '',
    mfaphoneenabled       varchar(10)  NOT NULL DEFAULT 'false',
    mfaemailenabled       varchar(10)  NOT NULL DEFAULT 'false',
    recoverycodes         text         NOT NULL DEFAULT '',
    externalid            varchar(100) NOT NULL DEFAULT '',
    passwordtype          varchar(100) NOT NULL DEFAULT '',
    avatartype            varchar(100) NOT NULL DEFAULT '',
    countrycode           varchar(100) NOT NULL DEFAULT '',
    realname              varchar(100) NOT NULL DEFAULT '',
    isverified            varchar(10)  NOT NULL DEFAULT 'false',
    mfaradiusenabled      varchar(10)  NOT NULL DEFAULT 'false',
    mfaradiususername     varchar(100) NOT NULL DEFAULT '',
    mfaradiusprovider     varchar(100) NOT NULL DEFAULT '',
    mfapushenabled        varchar(10)  NOT NULL DEFAULT 'false',
    mfapushreceiver       varchar(100) NOT NULL DEFAULT '',
    mfapushprovider       varchar(100) NOT NULL DEFAULT '',
    invitation            varchar(100) NOT NULL DEFAULT '',
    invitationcode        varchar(100) NOT NULL DEFAULT '',
    ldap                  varchar(100) NOT NULL DEFAULT '',
    lastsignintime        varchar(40)  NOT NULL DEFAULT '',
    lastsigninip          varchar(100) NOT NULL DEFAULT '',
    lastchangepasswordtime varchar(40) NOT NULL DEFAULT '',
    lastsigninwrongtime   varchar(40)  NOT NULL DEFAULT '',
    signinwrongtimes      varchar(20)  NOT NULL DEFAULT '0',
    needupdatepassword    varchar(10)  NOT NULL DEFAULT 'false',
    ipwhitelist           varchar(200) NOT NULL DEFAULT '',
    mfarememberdeadline   varchar(40)  NOT NULL DEFAULT '',
    webauthncredentials   text         NOT NULL DEFAULT '',
    faceids               text         NOT NULL DEFAULT '',
    managedaccounts       text         NOT NULL DEFAULT '',
    mfaaccounts           text         NOT NULL DEFAULT '',
    mfaitems              text         NOT NULL DEFAULT '',
    properties            text         NOT NULL DEFAULT '{}',  -- Casdoor 自定义属性 JSON

    -- ===== 派生列（D6 状态映射，由 trg_mirror_derive_status 维护）=====
    is_active             boolean      NOT NULL DEFAULT true,   -- = NOT isforbidden
    deleted_at            timestamptz,                          -- = isdeleted 时 now()

    -- ===== 本地审计列（syncer/webhook 写入时为 NULL）=====
    created_at            timestamptz  NOT NULL DEFAULT now(),
    updated_at            timestamptz  NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_by            uuid,
    deleted_by            uuid
);

COMMENT ON TABLE casdoor_user_mirror IS 'Casdoor 用户全量镜像表（业务系统唯一用户主表，D4）;身份字段由 Casdoor 同步，业务扩展字段见 sys_user_profile';
COMMENT ON COLUMN casdoor_user_mirror.id IS 'Casdoor 用户 Id（UUID），与 JWT sub 一致';
COMMENT ON COLUMN casdoor_user_mirror.name IS '用户名（Casdoor 登录名）';
COMMENT ON COLUMN casdoor_user_mirror.password IS 'Casdoor 密码哈希（仅供存档/对账，禁止业务验证）';
COMMENT ON COLUMN casdoor_user_mirror.isforbidden IS 'Casdoor 禁用标志（D6 源字段）';
COMMENT ON COLUMN casdoor_user_mirror.isdeleted IS 'Casdoor 删除标志（D6 源字段）';
COMMENT ON COLUMN casdoor_user_mirror.is_active IS '派生：NOT isforbidden';
COMMENT ON COLUMN casdoor_user_mirror.deleted_at IS '派生：isdeleted 时置 now()';
COMMENT ON COLUMN casdoor_user_mirror.properties IS 'Casdoor 自定义属性 JSON（map[string]string）';

CREATE INDEX IF NOT EXISTS idx_mirror_name ON casdoor_user_mirror(name);
CREATE INDEX IF NOT EXISTS idx_mirror_email ON casdoor_user_mirror(email);
CREATE INDEX IF NOT EXISTS idx_mirror_phone ON casdoor_user_mirror(phone);
CREATE INDEX IF NOT EXISTS idx_mirror_isactive ON casdoor_user_mirror(is_active);

-- ==============================================================================
-- 2. 派生触发器: D6 状态映射（isforbidden/isdeleted → is_active/deleted_at）
--    syncer / webhook / RPC 任何写入路径均生效
-- ==============================================================================
DROP TRIGGER IF EXISTS trg_mirror_derive_status ON casdoor_user_mirror;

CREATE OR REPLACE FUNCTION trg_mirror_derive_status_fn()
RETURNS trigger AS $$
BEGIN
    NEW.is_active := (NEW.isforbidden <> 'true');
    IF NEW.isdeleted = 'true' THEN
        NEW.deleted_at := COALESCE(NEW.deleted_at, now());
    ELSE
        NEW.deleted_at := NULL;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mirror_derive_status
BEFORE INSERT OR UPDATE ON casdoor_user_mirror
FOR EACH ROW EXECUTE FUNCTION trg_mirror_derive_status_fn();

-- ==============================================================================
-- 3. sys_user_profile 业务档案表（D3/D4/D5: 租户归属 + 扩展字段）
-- ==============================================================================
CREATE TABLE IF NOT EXISTS sys_user_profile (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id     uuid NOT NULL UNIQUE REFERENCES casdoor_user_mirror(id) ON DELETE CASCADE,
    tenant_id   uuid NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,  -- D5: 默认租户，规则留扩展
    dept_id     uuid REFERENCES sys_department(id) ON DELETE SET NULL,
    nickname    varchar(100),            -- 应用侧扩展字段示例
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    created_by  uuid,
    updated_by  uuid,
    deleted_by  uuid
);

COMMENT ON TABLE sys_user_profile IS '业务用户档案表（1:1 关联 casdoor_user_mirror）：租户/部门归属 + 应用扩展字段';
COMMENT ON COLUMN sys_user_profile.tenant_id IS '业务租户（D5: 同步用户默认挂 default 租户）';
CREATE INDEX IF NOT EXISTS idx_profile_tenant ON sys_user_profile(tenant_id);

-- ==============================================================================
-- 4. 存量数据: 备份旧 sys_user → sys_user_legacy，然后移除旧表（CASCADE 清 FK/视图）
-- ==============================================================================
DO $$
BEGIN
    IF to_regclass('public.sys_user') IS NOT NULL
       AND to_regclass('public.sys_user_legacy') IS NULL THEN
        EXECUTE 'CREATE TABLE sys_user_legacy AS SELECT * FROM sys_user';
        EXECUTE 'COMMENT ON TABLE sys_user_legacy IS ''旧 sys_user 数据备份（Phase 1 迁移前快照）''';
    END IF;
END $$;

-- 移除旧 sys_user（表或兼容视图，按 relkind 动态处理；CASCADE 清 FK/依赖视图）
DO $$
DECLARE v_relkind char;
BEGIN
    IF to_regclass('public.sys_user') IS NOT NULL THEN
        SELECT relkind INTO v_relkind FROM pg_class WHERE oid = 'public.sys_user'::regclass;
        IF v_relkind = 'v' THEN
            EXECUTE 'DROP VIEW public.sys_user CASCADE';
        ELSE
            EXECUTE 'DROP TABLE public.sys_user CASCADE';
        END IF;
    END IF;
END $$;

-- 清理指向旧用户的存量关联行（mirror 初始为空 → 旧引用全部清除;数据已备份至 legacy）
DELETE FROM sys_user_role WHERE user_id NOT IN (SELECT id FROM casdoor_user_mirror);
DELETE FROM sys_user_session WHERE user_id NOT IN (SELECT id FROM casdoor_user_mirror);
DELETE FROM sys_token_blacklist WHERE user_id IS NOT NULL AND user_id NOT IN (SELECT id FROM casdoor_user_mirror);
DELETE FROM sys_user_role_request
 WHERE user_id NOT IN (SELECT id FROM casdoor_user_mirror)
    OR applicant_id NOT IN (SELECT id FROM casdoor_user_mirror)
    OR (approver_id IS NOT NULL AND approver_id NOT IN (SELECT id FROM casdoor_user_mirror));

-- ==============================================================================
-- 5. 重建外键: 所有原引用 sys_user(id) 的约束 → casdoor_user_mirror(id)（D4）
-- ==============================================================================
DO $$
BEGIN
    -- sys_tenant 审计字段
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tenant_created_by') THEN
        ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tenant_updated_by') THEN
        ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_updated_by FOREIGN KEY (updated_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tenant_deleted_by') THEN
        ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_deleted_by FOREIGN KEY (deleted_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_department
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_dept_created_by') THEN
        ALTER TABLE sys_department ADD CONSTRAINT fk_dept_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_dept_updated_by') THEN
        ALTER TABLE sys_department ADD CONSTRAINT fk_dept_updated_by FOREIGN KEY (updated_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_dept_deleted_by') THEN
        ALTER TABLE sys_department ADD CONSTRAINT fk_dept_deleted_by FOREIGN KEY (deleted_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_role
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_role_created_by') THEN
        ALTER TABLE sys_role ADD CONSTRAINT fk_role_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_role_updated_by') THEN
        ALTER TABLE sys_role ADD CONSTRAINT fk_role_updated_by FOREIGN KEY (updated_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_role_deleted_by') THEN
        ALTER TABLE sys_role ADD CONSTRAINT fk_role_deleted_by FOREIGN KEY (deleted_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_api
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_api_created_by') THEN
        ALTER TABLE sys_api ADD CONSTRAINT fk_api_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_api_updated_by') THEN
        ALTER TABLE sys_api ADD CONSTRAINT fk_api_updated_by FOREIGN KEY (updated_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_api_deleted_by') THEN
        ALTER TABLE sys_api ADD CONSTRAINT fk_api_deleted_by FOREIGN KEY (deleted_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_menu
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_menu_created_by') THEN
        ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_menu_updated_by') THEN
        ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_updated_by FOREIGN KEY (updated_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_menu_deleted_by') THEN
        ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_deleted_by FOREIGN KEY (deleted_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_user_role
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_user_role_user_id') THEN
        ALTER TABLE sys_user_role ADD CONSTRAINT fk_user_role_user_id FOREIGN KEY (user_id) REFERENCES casdoor_user_mirror(id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_user_role_created_by') THEN
        ALTER TABLE sys_user_role ADD CONSTRAINT fk_user_role_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    -- sys_user_session
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_session_user_id') THEN
        ALTER TABLE sys_user_session ADD CONSTRAINT fk_session_user_id FOREIGN KEY (user_id) REFERENCES casdoor_user_mirror(id) ON DELETE CASCADE;
    END IF;
    -- sys_token_blacklist
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_blacklist_user_id') THEN
        ALTER TABLE sys_token_blacklist ADD CONSTRAINT fk_blacklist_user_id FOREIGN KEY (user_id) REFERENCES casdoor_user_mirror(id) ON DELETE CASCADE;
    END IF;
    -- sys_user_role_request
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_req_user_id') THEN
        ALTER TABLE sys_user_role_request ADD CONSTRAINT fk_req_user_id FOREIGN KEY (user_id) REFERENCES casdoor_user_mirror(id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_req_applicant_id') THEN
        ALTER TABLE sys_user_role_request ADD CONSTRAINT fk_req_applicant_id FOREIGN KEY (applicant_id) REFERENCES casdoor_user_mirror(id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_req_approver_id') THEN
        ALTER TABLE sys_user_role_request ADD CONSTRAINT fk_req_approver_id FOREIGN KEY (approver_id) REFERENCES casdoor_user_mirror(id);
    END IF;
    -- sys_role_api / sys_role_menu 审计字段
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_role_api_created_by') THEN
        ALTER TABLE sys_role_api ADD CONSTRAINT fk_role_api_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_role_menu_created_by') THEN
        ALTER TABLE sys_role_menu ADD CONSTRAINT fk_role_menu_created_by FOREIGN KEY (created_by) REFERENCES casdoor_user_mirror(id) ON DELETE SET NULL;
    END IF;
END $$;

-- ==============================================================================
-- 6. 兼容视图 public.sys_user（security_invoker=true，列结构与旧表一致）
--    读路径函数/视图/RPC 无需改动;写路径由 RPC 直写 mirror/profile
-- ==============================================================================
CREATE OR REPLACE VIEW public.sys_user
WITH (security_invoker = true) AS
SELECT m.id,
       m.name  AS username,
       NULL::text AS password_hash,          -- 密码由 Casdoor 管理（D8），不再在业务侧保留
       p.tenant_id,
       p.dept_id,
       m.email,
       m.phone,
       m.is_active,
       m.created_at,
       m.updated_at,
       m.deleted_at,
       m.created_by,
       m.updated_by,
       m.deleted_by
FROM casdoor_user_mirror m
LEFT JOIN sys_user_profile p ON p.user_id = m.id;

COMMENT ON VIEW public.sys_user IS 'Casdoor 用户兼容视图（替代旧表，D4）;安全调用者权限，RLS 由底层表生效';

-- ==============================================================================
-- 7. RLS（D5 租户隔离; 镜像表无租户字段，经 profile 关联判定）
-- ==============================================================================
-- 确保默认租户存在（003 种子从未应用过的库兜底；幂等）
INSERT INTO sys_tenant (id, tenant_code, tenant_name, status)
VALUES ('00000000-0000-0000-0000-000000000001', 'default', '默认租户', 'active')
ON CONFLICT (id) DO NOTHING;
INSERT INTO sys_department (id, dept_name, tenant_id)
VALUES ('00000000-0000-0000-0000-000000000002', '默认部门', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;
ALTER TABLE casdoor_user_mirror ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mirror_tenant_policy ON casdoor_user_mirror;
-- PERMISSIVE（OR 组合）: 仅 RESTRICTIVE 时所有行被默认拒绝（PG RLS 语义）
CREATE POLICY mirror_tenant_policy ON casdoor_user_mirror
USING (
    is_super_admin()
    OR id = current_user_id()
    OR EXISTS (
        SELECT 1 FROM sys_user_profile p
        WHERE p.user_id = casdoor_user_mirror.id
          AND p.tenant_id = current_tenant_id()
          AND p.deleted_at IS NULL
    )
);

ALTER TABLE sys_user_profile ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS profile_tenant_policy ON sys_user_profile;
CREATE POLICY profile_tenant_policy ON sys_user_profile
USING (
    is_super_admin()
    OR id = current_user_id()
    OR tenant_id = current_tenant_id()
);

-- ==============================================================================
-- 8. 权限（web_anon/authenticated 只读 mirror/profile/兼容视图）
-- ==============================================================================
GRANT SELECT ON casdoor_user_mirror TO web_anon, authenticated;
GRANT SELECT ON sys_user_profile TO web_anon, authenticated;
GRANT SELECT ON public.sys_user TO web_anon, authenticated;

-- ==============================================================================
-- migrate:down
-- ==============================================================================
DROP VIEW IF EXISTS public.sys_user;
DROP TABLE IF EXISTS sys_user_profile CASCADE;
DROP TABLE IF EXISTS casdoor_user_mirror CASCADE;

-- 从备份恢复旧表（若存在）
DO $$
BEGIN
    IF to_regclass('public.sys_user_legacy') IS NOT NULL
       AND to_regclass('public.sys_user') IS NULL THEN
        EXECUTE 'ALTER TABLE sys_user_legacy RENAME TO sys_user';
    END IF;
END $$;
-- 注意: FK/RLS/触发器需重跑 001/002 迁移 + apply-src（rls_policies.sql）
