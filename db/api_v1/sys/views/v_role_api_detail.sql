-- db/api_v1/sys/views/v_role_api_detail
-- T7: 重建为 iam_role_api 投影（Logto 语义），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_sys.v_role_api_detail CASCADE;
CREATE VIEW api_v1_sys.v_role_api_detail AS
SELECT
    ra.id AS role_id,
    ra.api_id,
    ra.created_at,
    ra.role_code,
    COALESCE(r.name, ra.role_code) AS role_name,
    a.path,
    a.method,
    a.api_name,
    a.is_active AS api_is_active
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code
JOIN sys_api a ON a.id = ra.api_id;
COMMENT ON VIEW api_v1_sys.v_role_api_detail IS '角色-API 明细视图（Logto 镜像：iam_role_api）';
