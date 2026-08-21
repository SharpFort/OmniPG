-- api_v1/platform/views/dict_data.sql
-- VIEW: api_v1_platform.dict_data（17 号文档归位：迁移 023_admin_p0_naming_perm.sql 删定义段，本文件为唯一权威）
-- 回放终态: 023_admin_p0_naming_perm.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_platform.dict_data AS
SELECT id, tenant_id, dict_name, item_label, item_value, item_type, is_default,
       sort_no, status, remark, created_at, updated_at, created_by, updated_by
FROM dict_data;
