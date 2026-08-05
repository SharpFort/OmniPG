-- db/api_v1/sys/views/v_user_role_detail.sql
-- 用户-角色关联详情视图（T7: user_tenants 成员关系 + tenants 镜像）
-- Logto 语义: 成员关系即授权面；组织角色绑定在 Logto organization_roles
-- 来源: 20260707000016_relationship_management.sql → T7 适配

CREATE OR REPLACE VIEW api_v1_sys.v_user_role_detail AS
SELECT
    ut.user_id,
    ut.organization_id AS role_id,
    ut.organization_id AS tenant_id,
    ut.joined_at AS created_at,
    u.username,
    u.primary_email AS email,
    t.name AS role_name,
    t.name AS tenant_name
FROM public.user_tenants ut
JOIN public.users u ON ut.user_id = u.id
JOIN public.tenants t ON ut.organization_id = t.id
WHERE u.is_suspended = FALSE;
COMMENT ON VIEW api_v1_sys.v_user_role_detail IS '用户-组织成员详情视图（Logto 镜像）';
