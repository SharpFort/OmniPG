-- 061_mirror_audit_cleanup.sql
-- 镜像表审计字段清理（2026-08-15 用户拍板）
--   原则：镜像表完全以 Logto 同步数据为准，不套用本项目审计模板。
--   users/tenants:     移除 updated_at / deleted_at / created_by / updated_by / deleted_by
--                      （保留 created_at + logto_updated_at 同步水位）
--   role/organization_role: 移除 updated_at（logto_updated_at 已承载同步语义）
-- 配套（源文件，非本文件）：
--   sync_user_delete / sync_tenant_delete 软删→硬删（方案 A：先解绑 user_profile.tenant_id）
--   sync_*_upsert / sync_user_suspension 去 updated_at
--   sys_user / v_user_list / v_system_stats / role / v_role_list / rpc_get_current_user 去审计列引用
-- 本文件仅承载表结构变更（含残留触发器清理，列删除前置）；幂等（apply-src 重放安全）。

-- §1 清理残留 updated_at 触发器（列删除前必须先解绑触发器）
DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
DROP TRIGGER IF EXISTS trg_tenants_updated_at ON tenants;
DROP TRIGGER IF EXISTS trg_role_updated_at ON role;
DROP TRIGGER IF EXISTS trg_organization_role_updated_at ON organization_role;

-- §2 users 列清理
ALTER TABLE users
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS deleted_at,
    DROP COLUMN IF EXISTS created_by,
    DROP COLUMN IF EXISTS updated_by,
    DROP COLUMN IF EXISTS deleted_by;

-- §3 tenants 列清理
ALTER TABLE tenants
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS deleted_at,
    DROP COLUMN IF EXISTS created_by,
    DROP COLUMN IF EXISTS updated_by,
    DROP COLUMN IF EXISTS deleted_by;

-- §4 role / organization_role 列清理
ALTER TABLE role DROP COLUMN IF EXISTS updated_at;
ALTER TABLE organization_role DROP COLUMN IF EXISTS updated_at;

-- §5 验证段（幂等重放自适应）
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(table_name || '.' || column_name, ', ')
      INTO v_bad
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND ( (table_name = 'users' AND column_name IN ('updated_at','deleted_at','created_by','updated_by','deleted_by'))
          OR (table_name = 'tenants' AND column_name IN ('updated_at','deleted_at','created_by','updated_by','deleted_by'))
          OR (table_name IN ('role','organization_role') AND column_name = 'updated_at') );

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '061 验证失败：残留审计列 %', v_bad;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgname IN ('trg_users_updated_at','trg_tenants_updated_at',
                                 'trg_role_updated_at','trg_organization_role_updated_at')
                  AND NOT tgisinternal) THEN
        RAISE EXCEPTION '061 验证失败：残留 updated_at 触发器';
    END IF;

    RAISE NOTICE '061 验证通过：镜像表审计列与残留触发器已清理';
END $$;
