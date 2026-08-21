-- db/api_v1/platform/views/v_dept_list.sql
-- 部门列表视图：含用户数量统计（T7: tenants 镜像替代 sys_tenant；2026-08-20 直连 users+user_profile，不再依赖 platform.sys_user 兼容视图）
-- 来源: 20260707000015_system_management_api.sql → T7 适配

CREATE OR REPLACE VIEW api_v1_platform.v_dept_list AS
SELECT
    d.id,
    d.dept_name,
    d.tenant_id,
    d.parent_id,
    t.name AS tenant_name,
    d.sort_order,
    d.is_active,
    d.created_at,
    d.updated_at,
    d.deleted_at,
    (SELECT COUNT(*) FROM platform.users u LEFT JOIN platform.user_profile p ON p.user_id = u.id WHERE p.dept_id = d.id AND u.deleted_at IS NULL) AS user_count
FROM platform.department d
LEFT JOIN platform.tenants t ON d.tenant_id = t.id;
COMMENT ON VIEW api_v1_platform.v_dept_list IS '部门列表视图：含用户数量统计';
