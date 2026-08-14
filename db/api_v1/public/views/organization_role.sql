-- api_v1/public/views/organization_role.sql
-- VIEW: api_v1_public.organization_role（17 号文档归位：迁移 048_organization_role_mirror.sql 删定义段，本文件为唯一权威）
-- 回放终态: 048_organization_role_mirror.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW api_v1_public.organization_role AS
SELECT id, name, description, created_at, updated_at
FROM organization_role;
