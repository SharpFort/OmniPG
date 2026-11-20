-- db/src/platform/functions/identity_refs_guard.sql
-- D27: 业务侧 FK 已指向 Logto 基表（public.users / public.organizations / public.tenants），
--      本文件仅保留“用户归属于某个 Organization”这一无法用简单 FK 表达的校验；
--      角色绑定完整性由 iam_role_menu / iam_role_data_scope 的
--      role_id / org_role_id FK 原生保证（validate_role_refs 已退役）。
--
-- 2026-11-20 locker 重构（阶段 3 pgTAP 零覆盖补齐暴露的事故）：
--   2b 批次为 TOCTOU 加固引入 SELECT ... FOR KEY SHARE，但行锁要求基表
--   UPDATE 权限——app_owner（D25 只读）从未持有，首次执行即 42501
--   "permission denied for table organization_user_relations"，带组织的
--   档案/岗位写入（岗位分配等核心管理流）在生产全断（e2e 只读不写故未暴露）。
--   修复：成员关系校验收敛到 platform.check_user_org_membership()，
--   owner=logto_locker（NOLOGIN + BYPASSRLS + 仅 organization_user_relations
--   的 SELECT/UPDATE，init-logto-reader.sh 创建授权）——UPDATE 权限只存在于
--   DEFINER 函数内，app_owner 本体仍无 Logto 表写权，D25 只读边界保持。
--   冷库回退：locker 角色/授权在 Logto 初始化（init-logto-reader.sh）后才存在，
--   本文件以 psql \gset+\if 条件创建 locker 函数；函数缺席时 guards 回退
--   无锁 EXISTS（仅 Logto 未初始化的冷库场景；完整性主路径 = 068 起的原生 FK）。

-- ---------------------------------------------------------------------------
-- 0) locker 函数：owner=logto_locker（FOR KEY SHARE 行锁 + BYPASSRLS 读 Logto RLS 表）
--    psql 条件创建（apply-src 冷库单遍契约：locker 角色未建时跳过，不失败）
-- ---------------------------------------------------------------------------
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'logto_locker') AS locker_exists \gset
\if :locker_exists
-- 角色为集群级（pg_roles 可见），但 schema 权限是库级的（init-logto-reader.sh
-- 仅在主库授 locker 的 CREATE）——冷启动验证库上须由 schema owner（app_owner）
-- 幂等补授，否则 DEFINER 函数创建 permission denied for schema platform
GRANT USAGE, CREATE ON SCHEMA platform TO logto_locker;
SET ROLE logto_locker;
CREATE OR REPLACE FUNCTION platform.check_user_org_membership(p_user_id text, p_organization_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    -- FOR KEY SHARE：锁定成员关系行直至调用方事务提交，并发的成员移除
    --（Logto 删除 organization_user_relations 行）阻塞等待——消除“校验通过后
    -- 成员被移除、档案成为孤儿归属”的 TOCTOU 竞态（2b 批次语义，本次真正可执行）
    RETURN EXISTS (
        SELECT 1 FROM public.organization_user_relations
        WHERE user_id = p_user_id AND organization_id = p_organization_id
        FOR KEY SHARE
    );
END;
$fn$;
COMMENT ON FUNCTION platform.check_user_org_membership(text, text) IS
'用户-组织成员关系校验（FOR KEY SHARE 行锁，TOCTOU 加固）；owner=logto_locker（D25：UPDATE 权限仅存在于本 DEFINER 函数内）';
REVOKE ALL ON FUNCTION platform.check_user_org_membership(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.check_user_org_membership(text, text) TO app_owner;
RESET ROLE;
\else
\echo 'identity_refs_guard: logto_locker 不存在（Logto 未初始化），跳过 check_user_org_membership 创建——guards 将以无锁 EXISTS 回退'
\endif

CREATE OR REPLACE FUNCTION platform.validate_user_profile_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
BEGIN
    -- 存在性由 FK 保证；此处校验组织成员关系（RLS/业务语义）
    IF NEW.user_id IS NULL THEN
        RAISE EXCEPTION 'user_profile.user_id cannot be null' USING ERRCODE = '23502';
    END IF;
    IF NEW.organization_id IS NOT NULL THEN
        IF to_regprocedure('platform.check_user_org_membership(text,text)') IS NOT NULL THEN
            -- locker 路径：FOR KEY SHARE 锁定成员行直至本事务提交（TOCTOU 加固）
            IF NOT platform.check_user_org_membership(NEW.user_id, NEW.organization_id) THEN
                RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
                    USING ERRCODE = '23503';
            END IF;
        ELSE
            -- 冷库回退（Logto 未初始化）：无锁 EXISTS；完整性主路径 = 068 起的原生 FK（d25-purge 调度已于 068 设计性退役）
            IF NOT EXISTS (SELECT 1 FROM platform.user_tenants
                           WHERE user_id = NEW.user_id AND organization_id = NEW.organization_id) THEN
                RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
                    USING ERRCODE = '23503';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profile_identity_refs ON platform.user_profile;
CREATE TRIGGER trg_user_profile_identity_refs
BEFORE INSERT OR UPDATE ON platform.user_profile
FOR EACH ROW EXECUTE FUNCTION platform.validate_user_profile_refs();

CREATE OR REPLACE FUNCTION platform.validate_user_position_refs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
BEGIN
    -- 存在性由 FK 保证；此处校验组织成员关系（RLS/业务语义）
    IF NEW.user_id IS NULL OR NEW.organization_id IS NULL THEN
        RAISE EXCEPTION 'user_position.user_id/organization_id cannot be null' USING ERRCODE = '23502';
    END IF;
    IF to_regprocedure('platform.check_user_org_membership(text,text)') IS NOT NULL THEN
        IF NOT platform.check_user_org_membership(NEW.user_id, NEW.organization_id) THEN
            RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
                USING ERRCODE = '23503';
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = NEW.user_id AND organization_id = NEW.organization_id) THEN
            RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
                USING ERRCODE = '23503';
        END IF;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.position WHERE id = NEW.position_id AND organization_id = NEW.organization_id) THEN
        RAISE EXCEPTION 'position % not found in organization %', NEW.position_id, NEW.organization_id
            USING ERRCODE = '23503';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_position_identity_refs ON platform.user_position;
CREATE TRIGGER trg_user_position_identity_refs
BEFORE INSERT OR UPDATE ON platform.user_position
FOR EACH ROW EXECUTE FUNCTION platform.validate_user_position_refs();
