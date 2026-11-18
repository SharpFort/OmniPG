-- db/src/platform/functions/identity_refs_guard.sql
-- D27: 业务侧 FK 已指向 Logto 基表（public.users / public.organizations / public.tenants），
--      本文件仅保留“用户归属于某个 Organization”这一无法用简单 FK 表达的校验；
--      角色绑定完整性由 iam_role_menu / iam_role_data_scope 的
--      role_id / org_role_id FK 原生保证（validate_role_refs 已退役）。

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
        IF NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = NEW.user_id AND organization_id = NEW.organization_id) THEN
            RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
                USING ERRCODE = '23503';
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
    IF NOT EXISTS (SELECT 1 FROM platform.user_tenants
                   WHERE user_id = NEW.user_id AND organization_id = NEW.organization_id) THEN
        RAISE EXCEPTION 'user % is not a member of organization %', NEW.user_id, NEW.organization_id
            USING ERRCODE = '23503';
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
