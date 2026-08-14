-- src/public/functions/sync_organization_role_delete.sql
-- FUNCTION: public.sync_organization_role_delete（17 号文档归位：迁移 048_organization_role_mirror.sql 删定义段，本文件为唯一权威）
-- 回放终态: 048_organization_role_mirror.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION sync_organization_role_delete(p_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM organization_role WHERE id = p_id;
END $$;
