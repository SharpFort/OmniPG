-- api_v1/public/views/position.sql
-- VIEW: api_v1_public.position（17 号文档归位：迁移 026_view_sys_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 026_view_sys_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_public.position AS
SELECT id, tenant_id, pos_name, pos_code, parent_id, sort_no, status, remark,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by
FROM position;
