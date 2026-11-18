-- db/api_v1/platform/views/v_role_list.sql
-- D27: 全局角色列表输出 tenant_id（Logto 租户），绑定计数按 role_id + organization_id='' 全局段。

DROP VIEW IF EXISTS api_v1_platform.v_role_list CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.v_role_list AS
SELECT
    r.id,
    r.tenant_id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text AS organization_id,
    r.description,
    true::boolean AS is_active,
    NULL::timestamptz AS deleted_at,
    t.name AS tenant_name,
    (SELECT count(*) FROM iam_role_menu rm JOIN iam_menu m ON m.id = rm.menu_id
     WHERE rm.role_id = r.id AND rm.tenant_id = r.tenant_id AND m.api_url IS NOT NULL) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_id = r.id AND rm.tenant_id = r.tenant_id) AS menu_count,
    (SELECT count(*) FROM platform.user_role ur WHERE ur.role_id = r.id AND ur.tenant_id = r.tenant_id AND ur.organization_id = '') AS users_count
FROM platform.role r
LEFT JOIN platform.tenants t ON r.tenant_id = t.id
WHERE r.tenant_id = current_logto_tenant_id();
COMMENT ON VIEW api_v1_platform.v_role_list IS '角色列表视图（D27：tenant_id=Logto 租户；按租户+全局段计数）';
