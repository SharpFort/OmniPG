DROP VIEW IF EXISTS api_v1_platform.department CASCADE;
-- db/api_v1/platform/views/sys_department
-- D27: department API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.department AS
SELECT id, dept_name, tenant_id, organization_id, parent_id, sort_order, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM platform.department;
COMMENT ON VIEW api_v1_platform.department IS '部门树视图（D27：tenant_id=Logto 租户；organization_id=业务组织）';
