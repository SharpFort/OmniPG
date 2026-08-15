-- src/public/functions/sync_tenant_delete.sql
-- FUNCTION: public.sync_tenant_delete（17 号文档归位：迁移 010_logto_webhook_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 010_logto_webhook_rpc.sql；幂等写法（§9 模板）
-- 061（2026-08-15）: 软删→硬删（镜像表以 Logto 为准）。方案 A（用户拍板）：
--   先解除该租户下用户档案的租户归属（user_profile.tenant_id 为 RESTRICT FK 前置）；
--   user_tenants 成员关系经 FK ON DELETE CASCADE 自动清理。

CREATE OR REPLACE FUNCTION sync_tenant_delete(org_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE user_profile SET tenant_id = NULL WHERE tenant_id = org_id;
    DELETE FROM tenants WHERE id = org_id;
END $$;
