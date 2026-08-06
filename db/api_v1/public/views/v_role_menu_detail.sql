-- db/api_v1/public/views/v_role_menu_detail.sql
-- T9: 列对齐当前 iam_menu（menu_name/menu_type/perms）
-- 来源: 20260707000013_postgrest_api_v1.sql（T9 改造）

DROP VIEW IF EXISTS api_v1_public.v_role_menu_detail CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.menu_name AS menu_name,
    m.menu_type AS menu_type,
    m.perms AS permission_code,
    m.path AS menu_path,
    m.icon AS menu_icon,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_public.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu）';