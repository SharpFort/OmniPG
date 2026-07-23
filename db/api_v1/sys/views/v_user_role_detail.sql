-- db/api_v1/sys/views/v_user_role_detail.sql
-- 用户-角色关联详情视图
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE VIEW api_v1.v_user_role_detail AS
SELECT 
    ur.user_id,
    ur.role_id,
    ur.tenant_id,
    ur.created_at,
    u.username,
    u.email,
    r.role_code,
    r.role_name,
    r.description AS role_description,
    t.tenant_name
FROM public.sys_user_role ur
JOIN public.sys_user u ON ur.user_id = u.id
JOIN public.sys_role r ON ur.role_id = r.id
LEFT JOIN public.sys_tenant t ON ur.tenant_id = t.id
WHERE u.deleted_at IS NULL AND r.deleted_at IS NULL;
COMMENT ON VIEW api_v1.v_user_role_detail IS '用户-角色关联详情视图';
