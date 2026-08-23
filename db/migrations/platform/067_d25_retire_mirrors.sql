-- 067_d25_retire_mirrors.sql
-- D25（2026-08-23）：同库只读落地——退役六张 Logto 镜像表与同步链路。
-- 数据读取改为 platform 内只读投影视图（db/src/platform/views/*，owner=omnipg_logto_reader）；
-- 业务 FK 改由 RPC + BEFORE 触发器 + pg_cron 孤儿清理保证（不跨 schema）。
-- 本迁移仅做 DDL 清理；视图/函数/触发器由 apply-src 归位。
-- migrate:up

-- 1. 删除指向镜像表的业务 FK（后续由触发器/清理任务保证完整性）
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_position_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_position DROP CONSTRAINT user_position_user_id_fkey;
    END IF;
END $$;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_tenant_id_fkey') THEN
        ALTER TABLE ONLY platform.user_profile DROP CONSTRAINT user_profile_tenant_id_fkey;
    END IF;
END $$;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_profile_user_id_fkey') THEN
        ALTER TABLE ONLY platform.user_profile DROP CONSTRAINT user_profile_user_id_fkey;
    END IF;
END $$;

-- 2. 丢弃旧暴露视图（api_v1_platform.organization_role 已被 tenant_role 取代）
DROP VIEW IF EXISTS api_v1_platform.organization_role CASCADE;

-- 3. 递归 drop 退役 sync 函数（PostSignIn 分支与 sync_login_log_write 保留）
DROP FUNCTION IF EXISTS platform.sync_user_upsert(jsonb);
DROP FUNCTION IF EXISTS platform.sync_user_delete(text);
DROP FUNCTION IF EXISTS platform.sync_user_suspension(text, boolean);
DROP FUNCTION IF EXISTS platform.sync_tenant_upsert(jsonb);
DROP FUNCTION IF EXISTS platform.sync_tenant_delete(text);
DROP FUNCTION IF EXISTS platform.sync_role_upsert(jsonb);
DROP FUNCTION IF EXISTS platform.sync_role_delete(text);
DROP FUNCTION IF EXISTS platform.sync_organization_role_upsert(jsonb);
DROP FUNCTION IF EXISTS platform.sync_organization_role_delete(text);
DROP FUNCTION IF EXISTS platform.sync_membership_delta(text, jsonb, jsonb);

-- 4. 删除镜像表（含旧 organization_role）；仅当仍是物理表时删除，
--    避免 apply-src 重放时误删同名只读投影视图。
DO $$ DECLARE v_tbl text; BEGIN
    FOR v_tbl IN
        SELECT n.nspname || '.' || c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'platform' AND c.relname IN
              ('users','tenants','role','organization_role','user_tenants','user_role')
          AND c.relkind IN ('r','p')
    LOOP
        EXECUTE format('DROP TABLE %s CASCADE', v_tbl);
    END LOOP;
END $$;

-- 5. 登记每日孤儿清理任务（替代 ON DELETE CASCADE / RESTRICT 语义）
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'd25-purge-identity-refs') THEN
        PERFORM cron.unschedule('d25-purge-identity-refs');
    END IF;
    PERFORM cron.schedule('d25-purge-identity-refs', '30 3 * * *',
                          $cron$SELECT platform.purge_orphan_identity_refs()$cron$);
END $$;

-- migrate:down
-- （无回滚：D25 为一次性拓扑变更；如需回退请从备份恢复或重建镜像表）
