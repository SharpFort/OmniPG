-- db/api_v1/sys/views/v_role_menu_detail
-- T7: 重建为 iam_role_menu 投影（Logto 语义），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_public.v_role_menu_detail CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.name AS menu_name,
    m.type AS menu_type,
    m.title AS menu_title,
    m.permission_code,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_public.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu）';
