-- db/api_v1/sys/views/v_dept_list.sql
-- 部门列表视图：含用户数量统计
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE VIEW api_v1.v_dept_list AS
SELECT 
    d.id,
    d.dept_name,
    d.tenant_id,
    d.parent_id,
    t.tenant_name,
    d.sort_order,
    d.is_active,
    d.created_at,
    d.updated_at,
    d.deleted_at,
    (SELECT COUNT(*) FROM public.sys_user u WHERE u.dept_id = d.id AND u.deleted_at IS NULL) AS user_count
FROM public.sys_department d
LEFT JOIN public.sys_tenant t ON d.tenant_id = t.id;
COMMENT ON VIEW api_v1.v_dept_list IS '部门列表视图：含用户数量统计';
