-- db/api_v1/public/views/iam_menu.sql（T9: 列对齐当前 iam_menu 表；038: +导航元字段；055: +端点/固定标签）
-- 来源: 20260707000013_postgrest_api_v1.sql（T9 改造）

CREATE OR REPLACE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, query, is_link, is_iframe, redirect, keep_alive,
       api_url, api_method, is_affix,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（055: +api_url/api_method/is_affix——单表化端点与固定标签）';
