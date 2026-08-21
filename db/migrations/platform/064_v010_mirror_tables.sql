-- 064_v010_mirror_tables.sql
-- v0.1.0 squash baseline（2026-08-16 用户拍板，方案 36-迁移基线合并）
--   IdP 镜像/绑定表结构：users、tenants、role、organization_role、user_tenants、user_role（6 张，text id）。FK 依赖：业务表（065）的 user_profile/user_position/user_role 等 FK 指向本文件表，必须先建。
--   来源：现库 pg_dump 反写（2026-08-15 审计追平终态，含 059-063 全部变更）。
--   17 号铁律：本文件仅承载表结构；RLS 策略/触发器/枚举/函数/视图归 src（apply-src 部署）。
--   幂等：CREATE IF NOT EXISTS / 约束 DO 守卫 / COMMENT 覆盖——apply-src 全量重放安全。
--   回滚：无 down 语义（squash baseline）；历史 62 个迁移见 git tag v0.1.0。
-- migrate:up
CREATE TABLE IF NOT EXISTS platform.role (
    id text CONSTRAINT iam_role_id_not_null NOT NULL,
    name character varying(128) CONSTRAINT iam_role_name_not_null NOT NULL,
    role_code text GENERATED ALWAYS AS (name) STORED,
    type character varying(32) DEFAULT 'User'::character varying CONSTRAINT iam_role_type_not_null NOT NULL,
    is_default boolean DEFAULT false CONSTRAINT iam_role_is_default_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT iam_role_created_at_not_null NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    logto_updated_at timestamp with time zone
);
COMMENT ON TABLE platform.role IS 'Logto 全局角色镜像（只读投影）；删除策略=硬删+级联——user_role.role_id FK ON DELETE CASCADE 显式清理分配镜像（N12 决策，049 建立）';
COMMENT ON COLUMN platform.role.role_code IS '生成列 = name（E5），与 iam_role_api.role_code / 网关 required_roles 对齐';
COMMENT ON COLUMN platform.role.description IS 'Logto Role.description（webhook/对账推送）';
COMMENT ON COLUMN platform.role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
CREATE TABLE IF NOT EXISTS platform.organization_role (
    id text NOT NULL,
    name character varying(128) NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    logto_updated_at timestamp with time zone
);
COMMENT ON TABLE platform.organization_role IS 'Logto 组织角色镜像表（独立于 role 全局角色；只读投影，写入通道 = sync_organization_role_*）';
COMMENT ON COLUMN platform.organization_role.id IS 'Logto organization role id（21 位 nanoid）';
COMMENT ON COLUMN platform.organization_role.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
CREATE TABLE IF NOT EXISTS platform.user_tenants (
    organization_id text NOT NULL,
    user_id text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE platform.user_tenants IS 'Logto 组织成员关系镜像（来源: Organization.Membership.Updated webhook）';
COMMENT ON COLUMN platform.user_tenants.joined_at IS '加入时间（本地近似）——Logto 成员 API 不返回加入时间；对账全量重建时保持首次观察值（N11 决策）';
CREATE TABLE IF NOT EXISTS platform.users (
    id text NOT NULL,
    username character varying(128) DEFAULT ''::character varying NOT NULL,
    primary_email character varying(255) DEFAULT ''::character varying NOT NULL,
    primary_phone character varying(32) DEFAULT ''::character varying NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    avatar character varying(500) DEFAULT ''::character varying NOT NULL,
    custom_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    identities jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_sign_in_at timestamp with time zone,
    is_suspended boolean DEFAULT false NOT NULL,
    application_id character varying(64) DEFAULT ''::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    profile jsonb DEFAULT '{}'::jsonb NOT NULL,
    sso_identities jsonb DEFAULT '{}'::jsonb NOT NULL,
    logto_updated_at timestamp with time zone
);
COMMENT ON TABLE platform.users IS 'Logto 用户镜像表（Logto 权威，PG 只读；不进授权判定路径）';
COMMENT ON COLUMN platform.users.id IS 'Logto 用户 id（21 位 nanoid 字符串，与服务端 JWT sub 一致）';
COMMENT ON COLUMN platform.users.primary_email IS 'Logto primaryEmail — 用户主邮箱';
COMMENT ON COLUMN platform.users.primary_phone IS 'Logto primaryPhone — 用户主电话';
COMMENT ON COLUMN platform.users.profile IS 'Logto User.profile（OIDC 标准 claims；仅 Management API 返回，对账任务 D9 注入）';
COMMENT ON COLUMN platform.users.sso_identities IS 'Logto User.ssoIdentities（企业 SSO 身份；仅 Management API 返回，对账任务 D9 注入）';
COMMENT ON COLUMN platform.users.logto_updated_at IS 'Logto 权威 updatedAt（webhook 无该字段时为本地近似）；乱序守护比较基准（N18）';
CREATE TABLE IF NOT EXISTS platform.tenants (
    id text NOT NULL,
    name character varying(255) DEFAULT ''::character varying NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    custom_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    logto_updated_at timestamp with time zone
);
COMMENT ON TABLE platform.tenants IS 'Logto 组织镜像表（租户容器；id = Logto organization id，与业务 tenant_id 同键）';
COMMENT ON COLUMN platform.tenants.id IS 'Logto organization id（21 位 nanoid）—— 业务表 tenant_id 的直接 FK 目标';
COMMENT ON COLUMN platform.tenants.logto_updated_at IS 'Logto 权威 updatedAt；乱序守护比较基准（N18）';
CREATE TABLE IF NOT EXISTS platform.user_role (
    user_id text NOT NULL,
    role_code text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    organization_id text DEFAULT ''::text NOT NULL,
    role_id text
);
COMMENT ON TABLE platform.user_role IS '用户↔角色分配镜像（Logto 权威；JIT 覆盖+主动同步+对账，05 §6.5；仅管理端展示）';
COMMENT ON COLUMN platform.user_role.organization_id IS '角色归属维度：'''' = 全局角色（Logto 全局 roles）；非空 = Logto organization id（组织角色）';
COMMENT ON COLUMN platform.user_role.role_id IS 'Logto 角色 id（对齐 users_roles 形状；镜像缺失时 NULL，对账/后续登录回填）';
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_pkey') THEN
        ALTER TABLE ONLY platform.role ADD CONSTRAINT iam_role_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organization_role_pkey') THEN
        ALTER TABLE ONLY platform.organization_role ADD CONSTRAINT organization_role_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenants_pkey') THEN
        ALTER TABLE ONLY platform.tenants ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_pkey') THEN
        ALTER TABLE ONLY platform.user_role ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, organization_id, role_code);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_tenants_pkey') THEN
        ALTER TABLE ONLY platform.user_tenants ADD CONSTRAINT user_tenants_pkey PRIMARY KEY (organization_id, user_id);
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_pkey') THEN
        ALTER TABLE ONLY platform.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
    END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS idx_org_role_name ON platform.organization_role USING btree (name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_role_name ON platform.role USING btree (name);
CREATE INDEX IF NOT EXISTS idx_role_type ON platform.role USING btree (type);
CREATE INDEX IF NOT EXISTS idx_tenants_name ON platform.tenants USING btree (name);
CREATE INDEX IF NOT EXISTS idx_users_is_suspended ON platform.users USING btree (is_suspended);
CREATE INDEX IF NOT EXISTS idx_users_primary_email ON platform.users USING btree (primary_email);
CREATE INDEX IF NOT EXISTS idx_users_username ON platform.users USING btree (username);
CREATE INDEX IF NOT EXISTS idx_ut_org ON platform.user_tenants USING btree (organization_id);
CREATE INDEX IF NOT EXISTS idx_ut_user ON platform.user_tenants USING btree (user_id);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_role_id_fk') THEN
        ALTER TABLE ONLY platform.user_role ADD CONSTRAINT user_role_role_id_fk FOREIGN KEY (role_id) REFERENCES platform.role(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_role_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_role ADD CONSTRAINT user_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES platform.users(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_tenants_organization_id_fkey') THEN
        ALTER TABLE ONLY platform.user_tenants ADD CONSTRAINT user_tenants_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES platform.tenants(id) ON DELETE CASCADE;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_tenants_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_tenants ADD CONSTRAINT user_tenants_user_id_fkey FOREIGN KEY (user_id) REFERENCES platform.users(id) ON DELETE CASCADE;
    END IF;
END $$;

-- migrate:down
-- （无回滚：squash baseline。历史迁移与回滚路径见 git tag v0.1.0 / 全库快照）
