-- 069_d27_tenant_org_columns.sql
-- D27（2026-08-23）：业务侧同时建模 Logto Tenant 与 Organization
--   1) 所有平台业务表新增 tenant_id（Logto 部署租户，默认 'default'）
--      与 organization_id（Logto Organization id，真实 id；全局表为 NULL）
--   2) 原“语义为组织”的 tenant_id 列改名为 organization_id
--   3) platform.tenants / platform.organizations 只读视图（由 src 定义）与 Logto 一一对应
--   4) FK 直挂 public.tenants(id) / public.organizations(id)
-- 前置：scripts/init-logto-fk-references.sh（GRANT REFERENCES）
-- migrate:up

-- =============================================================================
-- 1. 列改名：旧 tenant_id（业务组织语义）→ organization_id
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='audit_log' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='audit_log' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.audit_log RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='department' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='department' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.department RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='dict_data' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='dict_data' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.dict_data RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='dict_type' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='dict_type' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.dict_type RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='login_log' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='login_log' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.login_log RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='position' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='position' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform."position" RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='user_position' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='user_position' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.user_position RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='user_profile' AND column_name='tenant_id')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='platform' AND table_name='user_profile' AND column_name='organization_id') THEN
        ALTER TABLE ONLY platform.user_profile RENAME COLUMN tenant_id TO organization_id;
    END IF;
END $$;

-- =============================================================================
-- 2. 所有平台业务表补 dual 列（schema_migrations 为 dbmate 内部表，不纳入）
-- =============================================================================
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY[
        'app_config','audit_log','cron_job_log','department','dict_data','dict_type',
        'iam_menu','iam_role_data_scope','iam_role_menu','ip_geolite2_blocks',
        'ip_geolite2_city','ip_geolite2_locations','ip_region_v4','login_log',
        'position','user_position','user_profile','webhook_event_log'
    ] LOOP
        EXECUTE format('ALTER TABLE ONLY platform.%I ADD COLUMN IF NOT EXISTS organization_id text', t);
        EXECUTE format('ALTER TABLE ONLY platform.%I ADD COLUMN IF NOT EXISTS tenant_id text NOT NULL DEFAULT ''default''', t);
    END LOOP;
END $$;

-- =============================================================================
-- 3. 外键：tenant_id → public.tenants(id)（基础设施租户，删除应被阻止）
-- =============================================================================
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY[
        'app_config','audit_log','cron_job_log','department','dict_data','dict_type',
        'iam_menu','iam_role_data_scope','iam_role_menu','ip_geolite2_blocks',
        'ip_geolite2_city','ip_geolite2_locations','ip_region_v4','login_log',
        'position','user_position','user_profile','webhook_event_log'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t || '_tenant_id_fk') THEN
            EXECUTE format('ALTER TABLE ONLY platform.%I ADD CONSTRAINT %I FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE RESTRICT',
                           t, t || '_tenant_id_fk');
        END IF;
    END LOOP;
END $$;

-- =============================================================================
-- 4. 外键：organization_id → public.organizations(id)
--    组织删除时：核心租户表级联；历史/日志/全局类置 NULL 保留数据
-- =============================================================================
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['department','position','user_position'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t || '_organization_id_fk') THEN
            EXECUTE format('ALTER TABLE ONLY platform.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE',
                           t, t || '_organization_id_fk');
        END IF;
    END LOOP;
END $$;

DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY[
        'app_config','audit_log','cron_job_log','dict_data','dict_type','iam_menu',
        'iam_role_data_scope','iam_role_menu','ip_geolite2_blocks','ip_geolite2_city',
        'ip_geolite2_locations','ip_region_v4','login_log','user_profile','webhook_event_log'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t || '_organization_id_fk') THEN
            EXECUTE format('ALTER TABLE ONLY platform.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL',
                           t, t || '_organization_id_fk');
        END IF;
    END LOOP;
END $$;

-- =============================================================================
-- 5. 关键列索引
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_department_organization ON platform.department (organization_id);
CREATE INDEX IF NOT EXISTS idx_department_tenant ON platform.department (tenant_id);
CREATE INDEX IF NOT EXISTS idx_position_organization ON platform.position (organization_id);
CREATE INDEX IF NOT EXISTS idx_position_tenant ON platform.position (tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_position_organization ON platform.user_position (organization_id);
CREATE INDEX IF NOT EXISTS idx_user_position_tenant ON platform.user_position (tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_profile_organization ON platform.user_profile (organization_id);
CREATE INDEX IF NOT EXISTS idx_user_profile_tenant ON platform.user_profile (tenant_id);
CREATE INDEX IF NOT EXISTS idx_dict_data_organization ON platform.dict_data (organization_id);
CREATE INDEX IF NOT EXISTS idx_dict_type_organization ON platform.dict_type (organization_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_organization ON platform.audit_log (organization_id);
CREATE INDEX IF NOT EXISTS idx_login_log_organization ON platform.login_log (organization_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_tenant ON platform.iam_role_menu (tenant_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_tenant ON platform.iam_role_data_scope (tenant_id);

-- =============================================================================
-- 6. 旧 FK 约束名同步（D26 的 user_profile/user_position 组织列）
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='user_profile_tenant_id_fkey')
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='user_profile_organization_id_fkey') THEN
        ALTER TABLE ONLY platform.user_profile RENAME CONSTRAINT user_profile_tenant_id_fkey TO user_profile_organization_id_fkey;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname='user_position_tenant_id_fkey')
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='user_position_organization_id_fkey') THEN
        ALTER TABLE ONLY platform.user_position RENAME CONSTRAINT user_position_tenant_id_fkey TO user_position_organization_id_fkey;
    END IF;
END $$;

-- migrate:down
-- （无回滚：D27 为开发期拓扑变更；如需回退请从备份恢复）
