-- db/api_v1/public/views/v_role_api_detail.sql
-- T9: 列对齐当前 iam_api（name/api_code）与 role 镜像
-- 来源: 20260707000013_postgrest_api_v1.sql（T9 改造）

DROP VIEW IF EXISTS api_v1_public.v_role_api_detail CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_api_detail AS
SELECT
    ra.id AS role_id,
    ra.api_id,
    ra.created_at,
    ra.role_code,
    COALESCE(r.name, ra.role_code) AS role_name,
    a.path,
    a.method,
    a.name AS api_name,
    a.api_code,
    a.is_active AS api_is_active
FROM iam_role_api ra
JOIN role r ON r.role_code = ra.role_code
JOIN iam_api a ON a.id = ra.api_id;
COMMENT ON VIEW api_v1_public.v_role_api_detail IS '角色-API 明细视图（Logto 镜像：iam_role_api）';