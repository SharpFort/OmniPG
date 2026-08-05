-- =============================================================================
-- 016_role_rename.sql — T7: iam_role → role（镜像表命名统一）
-- =============================================================================
-- 命名体系（05 v2.1 E5 演进）:
--   无前缀 = Logto 只读镜像: users / tenants / user_tenants / role
--   iam_*  = PG 业务自主表: iam_api / iam_menu / iam_role_api / iam_role_menu
-- role 表为 Logto 角色目录镜像，只读（authenticated 仅 SELECT），
-- 由 webhook sync_role_upsert/delete 维护（SECURITY DEFINER）。
--
-- 无 down 段：apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 重命名 iam_role → role（幂等；ALTER RENAME 自动更新视图引用）
--     索引/注释/GRANT 一并迁移
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.iam_role') IS NOT NULL THEN
        ALTER TABLE public.iam_role RENAME TO role;
        ALTER INDEX IF EXISTS idx_iam_role_name RENAME TO idx_role_name;
        ALTER INDEX IF EXISTS idx_iam_role_type RENAME TO idx_role_type;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §2 同步函数体（prosrc 文本不随 RENAME 更新）— 重放 sync_role_*（010 已改源）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_role_upsert(data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO role (id, name, type, is_default, created_at)
    VALUES (
        data->>'id',
        COALESCE(data->>'name', ''),
        COALESCE(data->>'type', 'User'),
        COALESCE((data->>'isDefault')::boolean, false),
        now()
    )
    ON CONFLICT (id) DO UPDATE SET
        name       = EXCLUDED.name,
        type       = EXCLUDED.type,
        is_default = EXCLUDED.is_default,
        updated_at = now();
END $$;

CREATE OR REPLACE FUNCTION public.sync_role_delete(role_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM role WHERE id = role_id;
END $$;

-- ---------------------------------------------------------------------------
-- §3 只读保障（镜像表：authenticated 仅 SELECT；写路径仅 sync_* SECURITY DEFINER）
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.role FROM authenticated;
GRANT SELECT ON public.role TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_role_exists boolean := to_regclass('public.role') IS NOT NULL;
    v_old_exists  boolean := to_regclass('public.iam_role') IS NOT NULL;
    v_grants int;
BEGIN
    SELECT count(*) INTO v_grants FROM information_schema.role_table_grants
    WHERE table_name='role' AND grantee='authenticated';
    RAISE NOTICE '016: role 表存在=% iam_role 残留=% authenticated 权限数=%', v_role_exists, v_old_exists, v_grants;
END $$;
