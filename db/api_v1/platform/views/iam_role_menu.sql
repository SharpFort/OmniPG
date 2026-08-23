-- db/api_v1/platform/views/iam_role_menu.sql
-- D27: 角色-菜单关联视图输出 tenant_id/organization_id（角色绑定表新增双列）。

DROP VIEW IF EXISTS api_v1_platform.iam_role_menu CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.iam_role_menu AS
SELECT
    rm.id,
    rm.tenant_id,
    rm.organization_id,
    rm.role_id,
    rm.org_role_id,
    COALESCE(r.id, tr.id) AS role_ref_id,
    COALESCE(r.role_code, tr.name) AS role_code,
    COALESCE(r.name, tr.name) AS role_name,
    rm.menu_id,
    rm.created_at,
    rm.created_by
FROM iam_role_menu rm
LEFT JOIN platform.role r ON r.id = rm.role_id AND r.tenant_id = rm.tenant_id
LEFT JOIN platform.tenant_role tr ON tr.id = rm.org_role_id AND tr.tenant_id = rm.tenant_id;
COMMENT ON VIEW api_v1_platform.iam_role_menu IS '角色-菜单关联视图（D27：tenant_id/organization_id 双列；role_id/org_role_id FK 指向 Logto）';
