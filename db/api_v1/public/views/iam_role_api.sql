-- db/api_v1/sys/views/sys_role_api
-- T7: 重建为 iam_role_api 投影（role_id = role.id，兼容前端关联），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_public.iam_role_api CASCADE;
CREATE OR REPLACE VIEW api_v1_public.iam_role_api AS
SELECT r.id AS role_id, ra.api_id, ra.created_at, ra.created_by
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code;
COMMENT ON VIEW api_v1_public.iam_role_api IS '角色-API 关联视图（Logto 镜像：iam_role_api）';
