-- db/api_v1/platform/views/v_role_menu_detail.sql
-- D27: 角色-菜单明细输出 tenant_id/organization_id 双列。

DROP VIEW IF EXISTS api_v1_platform.v_role_menu_detail CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.tenant_id,
    rm.organization_id,
    rm.menu_id,
    rm.created_at,
    COALESCE(r.role_code, tr.name) AS role_code,
    COALESCE(r.name, tr.name) AS role_name,
    m.menu_name AS menu_name,
    m.menu_type AS menu_type,
    m.api_code AS permission_code,
    m.router AS menu_path,
    m.icon AS menu_icon,
    m.parent_id AS menu_parent_id,
    m.api_url,
    m.api_method,
    m.is_affix
FROM iam_role_menu rm
LEFT JOIN platform.role r ON r.id = rm.role_id AND r.tenant_id = rm.tenant_id
LEFT JOIN platform.tenant_role tr ON tr.id = rm.org_role_id AND tr.tenant_id = rm.tenant_id
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_platform.v_role_menu_detail IS '角色-菜单明细视图（D27：双列输出）';
