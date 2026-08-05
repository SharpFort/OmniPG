-- db/api_v1/sys/views/sys_role_menu
-- T7: 重建为 iam_role_menu 投影（role_id = role.id，兼容前端关联），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_sys.sys_role_menu CASCADE;
CREATE VIEW api_v1_sys.sys_role_menu AS
SELECT r.id AS role_id, rm.menu_id, rm.created_at, rm.created_by
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code;
COMMENT ON VIEW api_v1_sys.sys_role_menu IS '角色-菜单关联视图（Logto 镜像：iam_role_menu）';
