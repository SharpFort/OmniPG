-- api_v1/public/views/login_log.sql
-- VIEW: api_v1_public.login_log（17 号文档归位：迁移 023_admin_p0_naming_perm.sql 删定义段，本文件为唯一权威）
-- 回放终态: 023_admin_p0_naming_perm.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_public.login_log AS
SELECT id, tenant_id, user_id, username, login_type, result, fail_reason,
       ip, user_agent, region, logto_event, created_at
FROM login_log;
