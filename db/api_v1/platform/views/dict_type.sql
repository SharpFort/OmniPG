DROP VIEW IF EXISTS api_v1_platform.dict_type CASCADE;
-- api_v1/platform/views/dict_type.sql
-- D27: dict_type API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.dict_type AS
SELECT id, tenant_id, organization_id, dict_name, dict_label, status, sort_no, remark,
       created_at, updated_at, created_by, updated_by
FROM dict_type;
