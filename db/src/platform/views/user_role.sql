-- db/src/platform/views/user_role.sql
-- D27：platform.user_role = 用户-角色分配只读投影
--   全局段 = Logto public.users_roles（organization_id 恒 NULL/''）
--   租户段 = Logto public.organization_role_user_relations（organization_id=组织 id）
-- 双列输出：tenant_id（Logto 部署租户）、organization_id（Logto Organization，全局段为 ''）。

DROP VIEW IF EXISTS platform.user_role CASCADE;
CREATE VIEW platform.user_role AS
SELECT
    ur.user_id,
    ur.tenant_id,
    ''::text AS organization_id,
    r.name AS role_code,
    ur.role_id
FROM public.users_roles ur
JOIN public.roles r ON r.id = ur.role_id
UNION ALL
SELECT
    orur.user_id,
    orur.tenant_id,
    orur.organization_id,
    orol.name AS role_code,
    orur.organization_role_id AS role_id
FROM public.organization_role_user_relations orur
JOIN public.organization_roles orol ON orol.id = orur.organization_role_id;
GRANT SELECT ON platform.user_role TO app_owner;
COMMENT ON VIEW platform.user_role IS '用户-角色分配只读投影（D27；tenant_id=Logto 部署租户；organization_id=Logto Organization，全局段为空串）';
