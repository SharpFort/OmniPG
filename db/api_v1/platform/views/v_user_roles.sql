-- api_v1/platform/views/v_user_roles.sql
-- VIEW: api_v1_platform.v_user_roles（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_platform.v_user_roles AS
SELECT u.id AS user_id, u.username, u.primary_email AS email,
       ur.role_code, ur.created_at AS assigned_at
FROM users u
LEFT JOIN user_role ur ON ur.user_id = u.id;
