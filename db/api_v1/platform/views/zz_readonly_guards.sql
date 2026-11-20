-- db/api_v1/platform/views/zz_readonly_guards.sql
-- Logto 只读投影 INSTEAD OF 写拒绝触发器（2026-11-20，阶段 3 e2e 收尾）
--
-- zz_ 前缀：本文件必须在 views 段末尾执行——前置依赖 users/role/tenants/
--   tenant_role/organizations/user_tenants 六个视图已建（apply-src views 段按字母序）。
-- 视图重放契约：views/*.sql 首行 DROP VIEW ... CASCADE 会连带删除挂载其上的触发器，
--   故本文件必须随 views 段每遍重放（幂等：DROP TRIGGER IF EXISTS + CREATE）。
-- 事件覆盖：INSERT OR UPDATE OR DELETE（TRUNCATE 不适用于视图，无对应事件）；
--   触发器函数 platform.reject_projection_write() RAISE 42501 → PostgREST 403。
-- 与 077 迁移（ACL 收权）的关系：双层防线——本触发器解决 JOIN 视图 55000→500
--   （改写早于 ACL，收权无法改变错误类型）与单表视图依赖 RLS 兜底的侥幸通过。

DROP TRIGGER IF EXISTS trg_users_readonly ON api_v1_platform.users;
CREATE TRIGGER trg_users_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.users
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();

DROP TRIGGER IF EXISTS trg_role_readonly ON api_v1_platform.role;
CREATE TRIGGER trg_role_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.role
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();

DROP TRIGGER IF EXISTS trg_tenants_readonly ON api_v1_platform.tenants;
CREATE TRIGGER trg_tenants_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.tenants
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();

DROP TRIGGER IF EXISTS trg_tenant_role_readonly ON api_v1_platform.tenant_role;
CREATE TRIGGER trg_tenant_role_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.tenant_role
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();

DROP TRIGGER IF EXISTS trg_organizations_readonly ON api_v1_platform.organizations;
CREATE TRIGGER trg_organizations_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.organizations
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();

DROP TRIGGER IF EXISTS trg_user_tenants_readonly ON api_v1_platform.user_tenants;
CREATE TRIGGER trg_user_tenants_readonly
    INSTEAD OF INSERT OR UPDATE OR DELETE ON api_v1_platform.user_tenants
    FOR EACH ROW EXECUTE FUNCTION platform.reject_projection_write();
