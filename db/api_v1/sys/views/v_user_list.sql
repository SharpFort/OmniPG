-- db/api_v1/sys/views/v_user_list.sql
-- 用户列表视图：含租户名、部门名、角色列表
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE VIEW api_v1_sys.v_user_list AS
SELECT 
    u.id,
    u.username,
    u.email,
    u.phone,
    u.tenant_id,
    u.dept_id,
    t.tenant_name,
    t.tenant_code,
    d.dept_name,
    u.is_active,
    u.created_at,
    u.updated_at,
    u.deleted_at,
    COALESCE(
        (SELECT json_agg(r.role_code ORDER BY r.role_code)
         FROM public.sys_user_role ur2
         JOIN public.sys_role r ON ur2.role_id = r.id
         WHERE ur2.user_id = u.id AND r.deleted_at IS NULL),
        '[]'::json
    ) AS roles
FROM public.sys_user u
LEFT JOIN public.sys_tenant t ON u.tenant_id = t.id
LEFT JOIN public.sys_department d ON u.dept_id = d.id;
COMMENT ON VIEW api_v1_sys.v_user_list IS '用户列表视图：含租户名、部门名、角色列表';
