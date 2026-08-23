DROP VIEW IF EXISTS api_v1_platform.iam_menu CASCADE;
-- db/api_v1/platform/views/iam_menu.sql
-- D27: iam_menu API 增加 tenant_id/organization_id（organization_id 全局表为 NULL）。

CREATE OR REPLACE VIEW api_v1_platform.iam_menu AS
SELECT id, tenant_id, organization_id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, is_link, is_iframe, redirect, is_cache,
       api_url, api_method, is_affix,
       created_at, updated_at, created_by, updated_by
FROM platform.iam_menu;
COMMENT ON VIEW api_v1_platform.iam_menu IS '菜单表视图（D27：tenant_id=Logto 租户；organization_id 全局 NULL）';
