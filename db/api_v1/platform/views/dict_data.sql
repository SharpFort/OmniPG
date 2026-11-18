DROP VIEW IF EXISTS api_v1_platform.dict_data CASCADE;
-- api_v1/platform/views/dict_data.sql
-- D27: dict_data API 输出 tenant_id/organization_id 双列。

CREATE OR REPLACE VIEW api_v1_platform.dict_data AS
SELECT id, tenant_id, organization_id, dict_name, item_label, item_value, item_type, is_default,
       sort_no, status, remark, created_at, updated_at, created_by, updated_by
FROM dict_data;
