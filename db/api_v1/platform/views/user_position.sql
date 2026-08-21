-- api_v1/platform/views/user_position.sql
-- VIEW: api_v1_platform.user_position（17 号文档归位：迁移 026_view_sys_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 026_view_sys_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_platform.user_position AS
SELECT user_id, position_id, tenant_id, is_primary, created_at, created_by
FROM user_position;
