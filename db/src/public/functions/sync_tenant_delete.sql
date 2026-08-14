-- src/public/functions/sync_tenant_delete.sql
-- FUNCTION: public.sync_tenant_delete（17 号文档归位：迁移 010_logto_webhook_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 010_logto_webhook_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION sync_tenant_delete(org_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE tenants SET deleted_at = now(), updated_at = now()
    WHERE id = org_id AND deleted_at IS NULL;
END $$;
