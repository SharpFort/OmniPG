DROP VIEW IF EXISTS api_v1_platform.position CASCADE;
-- api_v1/platform/views/position.sql
-- D27: position API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.position AS
SELECT id, tenant_id, organization_id, pos_name, pos_code, parent_id, sort_no, status, remark,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM position;
