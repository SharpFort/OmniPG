-- db/src/platform/views/users.sql
-- D25/D27：platform.users = Logto public.users（包含 default/admin 等全部 Logto Tenant）
-- owner = omnipg_logto_reader（BYPASSRLS + 列级 SELECT），业务角色仅经本层/API 层读取。
-- 敏感列（password_encrypted 等）不暴露；tenant_id = Logto 部署租户。

DROP VIEW IF EXISTS platform.users CASCADE;
CREATE VIEW platform.users AS
SELECT
    u.id,
    u.tenant_id,
    u.username,
    u.primary_email,
    u.primary_phone,
    u.name,
    u.avatar,
    u.is_suspended,
    u.created_at,
    u.updated_at
FROM public.users u;
GRANT SELECT ON platform.users TO app_owner;
COMMENT ON VIEW platform.users IS 'Logto 用户只读投影（D27；包含全部 Logto Tenant；排除密码/标识敏感列；tenant_id=Logto 部署租户）';
