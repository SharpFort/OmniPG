-- api_v1/public/views/v_role_users.sql
-- VIEW: api_v1_public.v_role_users（17 号文档归位：迁移 035_rpc_cleanup_unify.sql 删定义段，本文件为唯一权威）
-- 回放终态: 035_rpc_cleanup_unify.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_public.v_role_users AS
SELECT r.name AS role_code, r.id AS role_id, r.type AS role_type,
       ur.user_id, u.username
FROM role r
LEFT JOIN user_role ur ON ur.role_code = r.role_code
LEFT JOIN users u ON u.id = ur.user_id;
