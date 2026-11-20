DROP VIEW IF EXISTS api_v1_platform.v_dept_list CASCADE;
-- db/api_v1/platform/views/v_dept_list.sql
-- D27: 部门列表：tenant_id（Logto 租户）+ organization_id（Logto Organization）+ 组织名/租户名。

CREATE OR REPLACE VIEW api_v1_platform.v_dept_list AS
SELECT
    d.id,
    d.dept_name,
    d.tenant_id,
    d.organization_id,
    d.parent_id,
    o.name AS organization_name,
    t.name AS tenant_name,
    d.sort_order,
    d.is_active,
    d.created_at,
    d.updated_at,
    d.deleted_at,
    (SELECT COUNT(*) FROM api_v1_platform.users u WHERE u.dept_id = d.id AND u.deleted_at IS NULL) AS user_count
FROM platform.department d
LEFT JOIN platform.organizations o ON d.organization_id = o.id
LEFT JOIN platform.tenants t ON d.tenant_id = t.id
-- 租户/组织谓词（2026-11-19 修复）：本视图为 owner 执行（department 基表 RLS 不生效），
-- 此前 authenticated 可见全部租户/组织的部门；与 get_dept_tree 的 v_org 语义对齐
WHERE d.tenant_id = current_logto_tenant_id_strict()
  AND (d.organization_id = current_organization_id() OR d.organization_id IS NULL AND current_organization_id() IS NULL);
COMMENT ON VIEW api_v1_platform.v_dept_list IS '部门列表视图（D27：含 organization_name/tenant_name；租户/组织谓词限定）';
