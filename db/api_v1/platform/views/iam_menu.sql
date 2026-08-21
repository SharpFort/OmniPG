-- db/api_v1/platform/views/iam_menu.sql（T9: 列对齐当前 iam_menu 表；038: +导航元字段；055: +端点/固定标签；056: -query；057: keep_alive→is_cache）
-- 来源: 20260707000013_postgrest_api_v1.sql（T9 改造）

CREATE OR REPLACE VIEW api_v1_platform.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, is_link, is_iframe, redirect, is_cache,
       api_url, api_method, is_affix,
       created_at, updated_at, created_by, updated_by
FROM platform.iam_menu;
COMMENT ON VIEW api_v1_platform.iam_menu IS '菜单表视图（057: keep_alive→is_cache 改名——SharpFort IsCache 语义 + is_ 前缀统一；056: -query B1 清理）';
