-- 070_d27b_cleanup_stale_tenant_fks.sql
-- D27b（2026-08-28）：清理 apply-src 幂等重放引入的脏外键
-- 根因：068（D26）的幂等守卫仅按约束名检查；069（D27）把
--   user_profile / user_position 的 tenant_id 列改名为 organization_id，
--   并把约束 *_tenant_id_fkey 改名为 *_organization_id_fkey。此后
--   apply-src 全量重放 068 时守卫落空，把“组织语义”的旧约束重新挂到
--   069 新增的 tenant_id 列（REFERENCES public.organizations），与
--   *_tenant_id_fk（REFERENCES public.tenants）并存。默认值 'default'
--   只存在于 public.tenants，不存在于 public.organizations，导致
--   ensure_user 建档 INSERT 触发 23503 外键冲突（PostgREST 映射 409）。
-- 修复：仅删除附着在 tenant_id 列上、且指向 public.organizations 的旧
--   约束；保留 organization_id→organizations 与 tenant_id→tenants 的
--   正确约束。068 的守卫已同步加固，重放不再重建脏约束。
-- 前置：无（仅 DDL，表 owner 即可执行）。
-- migrate:up

DO $$ DECLARE r record; BEGIN
    FOR r IN
        SELECT con.conname, con.conrelid::regclass::text AS tbl
        FROM pg_constraint con
        JOIN pg_attribute att
          ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
        JOIN pg_class tbl ON tbl.oid = con.conrelid
        JOIN pg_namespace tbl_ns ON tbl_ns.oid = tbl.relnamespace
        JOIN pg_class ref ON ref.oid = con.confrelid
        JOIN pg_namespace ref_ns ON ref_ns.oid = ref.relnamespace
        WHERE con.contype = 'f'
          AND con.conname IN ('user_profile_tenant_id_fkey', 'user_position_tenant_id_fkey')
          AND tbl_ns.nspname = 'platform'
          AND tbl.relname IN ('user_profile', 'user_position')
          AND att.attname = 'tenant_id'
          AND ref.relname = 'organizations'
          AND ref_ns.nspname = 'public'
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
    END LOOP;
END $$;

-- migrate:down
-- （无回滚：仅删除脏约束；如需重建请重放旧版 068）
