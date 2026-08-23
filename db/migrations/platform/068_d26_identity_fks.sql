-- 068_d26_identity_fks.sql
-- D26（2026-08-23）：业务侧直接外键指向 Logto public 基表 + 角色绑定 ID 化
--   1) platform.user_profile / user_position 直挂 public.users / public.organizations
--   2) iam_role_menu / iam_role_data_scope 由 role_code 升级为 role_id + org_role_id
--      （分别 FK 到 public.roles(id) / public.organization_roles(id)，CHECK 恰好一个非空）
--   3) 退役 d25-purge-identity-refs（FK 原生保证完整性）
-- 前置：scripts/init-logto-fk-references.sh 已由 superuser 执行（GRANT REFERENCES）
-- 铁律：本文件仅 DDL/DML；函数/视图/触发器归 db/src 与 db/api_v1（apply-src 部署）。
-- migrate:up

-- =============================================================================
-- 0. 退役 D25 触发器化角色校验与每日孤儿清理（FK 已原生覆盖）
-- =============================================================================
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'd25-purge-identity-refs') THEN
        PERFORM cron.unschedule('d25-purge-identity-refs');
    END IF;
END $$;

DROP FUNCTION IF EXISTS platform.purge_orphan_identity_refs();

DROP TRIGGER IF EXISTS trg_iam_role_menu_role_refs ON platform.iam_role_menu;
DROP TRIGGER IF EXISTS trg_iam_role_data_scope_role_refs ON platform.iam_role_data_scope;
DROP FUNCTION IF EXISTS platform.validate_role_refs();

-- =============================================================================
-- 1. 用户/租户：平台业务表直接引用 Logto public 基表
-- =============================================================================
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_profile
            ADD CONSTRAINT user_profile_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_tenant_id_fkey') THEN
        ALTER TABLE ONLY platform.user_profile
            ADD CONSTRAINT user_profile_tenant_id_fkey
            FOREIGN KEY (tenant_id) REFERENCES public.organizations(id) ON DELETE SET NULL;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_position
            ADD CONSTRAINT user_position_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_tenant_id_fkey') THEN
        ALTER TABLE ONLY platform.user_position
            ADD CONSTRAINT user_position_tenant_id_fkey
            FOREIGN KEY (tenant_id) REFERENCES public.organizations(id) ON DELETE CASCADE;
    END IF;
END $$;

-- =============================================================================
-- 2. 角色绑定表：role_code -> role_id + org_role_id
-- =============================================================================

-- 2.0 首次迁移（role_code 列仍存在）时移除依赖旧列的视图；apply-src 随后按新定义重建。
--      幂等重放（apply-src 阶段）时 role_code 已不存在，不再 DROP，避免视图被反复删除。
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'platform' AND table_name = 'iam_role_menu'
                 AND column_name = 'role_code') THEN
        DROP VIEW IF EXISTS api_v1_platform.iam_role_menu;
        DROP VIEW IF EXISTS api_v1_platform.v_role_menu_detail;
        DROP VIEW IF EXISTS api_v1_platform.v_role_list;
        DROP VIEW IF EXISTS platform.casbin_rule;
    END IF;
END $$;

-- 2.1 旧唯一键退役
ALTER TABLE ONLY platform.iam_role_menu DROP CONSTRAINT IF EXISTS iam_role_menu_role_code_menu_id_key;
ALTER TABLE ONLY platform.iam_role_data_scope DROP CONSTRAINT IF EXISTS iam_role_data_scope_role_code_scope_type_dept_id_key;

-- 2.2 新列
ALTER TABLE ONLY platform.iam_role_menu ADD COLUMN IF NOT EXISTS role_id text;
ALTER TABLE ONLY platform.iam_role_menu ADD COLUMN IF NOT EXISTS org_role_id text;
ALTER TABLE ONLY platform.iam_role_data_scope ADD COLUMN IF NOT EXISTS role_id text;
ALTER TABLE ONLY platform.iam_role_data_scope ADD COLUMN IF NOT EXISTS org_role_id text;

-- 2.3 回填（走 platform 只读投影视图解析 Logto 角色——app_owner 直读 public.* 受 RLS 过滤；
--      仅首次迁移 role_code 列存在时执行，保证 apply-src 幂等重放安全）
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'platform' AND table_name = 'iam_role_menu'
                 AND column_name = 'role_code') THEN
        UPDATE platform.iam_role_menu rm
        SET role_id = g.id
        FROM platform.role g
        WHERE g.role_code = rm.role_code
          AND rm.role_id IS NULL AND rm.org_role_id IS NULL;

        UPDATE platform.iam_role_menu rm
        SET org_role_id = g.id
        FROM platform.tenant_role g
        WHERE g.name = rm.role_code
          AND rm.role_id IS NULL AND rm.org_role_id IS NULL;

        -- 2.4 清理真正无法解析的孤儿绑定（角色已从 Logto 删除；与原 CASCADE/purge 语义一致）
        DELETE FROM platform.iam_role_menu
        WHERE role_id IS NULL AND org_role_id IS NULL;
    END IF;
END $$;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'platform' AND table_name = 'iam_role_data_scope'
                 AND column_name = 'role_code') THEN
        UPDATE platform.iam_role_data_scope rs
        SET role_id = g.id
        FROM platform.role g
        WHERE g.role_code = rs.role_code
          AND rs.role_id IS NULL AND rs.org_role_id IS NULL;

        UPDATE platform.iam_role_data_scope rs
        SET org_role_id = g.id
        FROM platform.tenant_role g
        WHERE g.name = rs.role_code
          AND rs.role_id IS NULL AND rs.org_role_id IS NULL;

        -- 2.4 同上
        DELETE FROM platform.iam_role_data_scope
        WHERE role_id IS NULL AND org_role_id IS NULL;
    END IF;
END $$;

-- 2.5 CHECK：恰好一个标识非空
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_role_ref_check') THEN
        ALTER TABLE ONLY platform.iam_role_menu ADD CONSTRAINT iam_role_menu_role_ref_check
            CHECK ((role_id IS NOT NULL AND org_role_id IS NULL)
                OR (role_id IS NULL AND org_role_id IS NOT NULL));
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_role_ref_check') THEN
        ALTER TABLE ONLY platform.iam_role_data_scope ADD CONSTRAINT iam_role_data_scope_role_ref_check
            CHECK ((role_id IS NOT NULL AND org_role_id IS NULL)
                OR (role_id IS NULL AND org_role_id IS NOT NULL));
    END IF;
END $$;

-- 2.6 新唯一索引（ON CONFLICT 目标）
CREATE UNIQUE INDEX IF NOT EXISTS iam_role_menu_role_menu_key
    ON platform.iam_role_menu (role_id, org_role_id, menu_id);
CREATE UNIQUE INDEX IF NOT EXISTS iam_role_data_scope_role_scope_key
    ON platform.iam_role_data_scope (role_id, org_role_id, scope_type, dept_id);

-- 2.7 直接 FK 到 Logto 基表
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_role_id_fk') THEN
        ALTER TABLE ONLY platform.iam_role_menu
            ADD CONSTRAINT iam_role_menu_role_id_fk
            FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_menu_org_role_id_fk') THEN
        ALTER TABLE ONLY platform.iam_role_menu
            ADD CONSTRAINT iam_role_menu_org_role_id_fk
            FOREIGN KEY (org_role_id) REFERENCES public.organization_roles(id) ON DELETE CASCADE;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_role_id_fk') THEN
        ALTER TABLE ONLY platform.iam_role_data_scope
            ADD CONSTRAINT iam_role_data_scope_role_id_fk
            FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_role_data_scope_org_role_id_fk') THEN
        ALTER TABLE ONLY platform.iam_role_data_scope
            ADD CONSTRAINT iam_role_data_scope_org_role_id_fk
            FOREIGN KEY (org_role_id) REFERENCES public.organization_roles(id) ON DELETE CASCADE;
    END IF;
END $$;

-- 2.8 新列索引
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_role_id ON platform.iam_role_menu (role_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_menu_org_role_id ON platform.iam_role_menu (org_role_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_role_id ON platform.iam_role_data_scope (role_id);
CREATE INDEX IF NOT EXISTS idx_iam_role_data_scope_org_role_id ON platform.iam_role_data_scope (org_role_id);

-- =============================================================================
-- 3. 删除 role_code（旧索引随列自动删除）
-- =============================================================================
ALTER TABLE ONLY platform.iam_role_menu DROP COLUMN IF EXISTS role_code;
ALTER TABLE ONLY platform.iam_role_data_scope DROP COLUMN IF EXISTS role_code;

-- migrate:down
-- （无回滚：D26 为一次性拓扑变更；如需回退请从备份恢复或重建 role_code 绑定）
