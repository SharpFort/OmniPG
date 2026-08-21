-- db/api_v1/public/views/sys_department
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_public.department AS
SELECT id, dept_name, tenant_id, parent_id, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM platform.department;
COMMENT ON VIEW api_v1_public.department IS '部门树视图';
