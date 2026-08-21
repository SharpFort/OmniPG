-- src/platform/functions/sync_user_delete.sql
-- FUNCTION: platform.sync_user_delete（17 号文档归位：迁移 010_logto_webhook_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 010_logto_webhook_rpc.sql；幂等写法（§9 模板）
-- 061（2026-08-15）: 软删→硬删。镜像表以 Logto 为准：Logto 删除 = 行删除；
--   user_profile/user_role/user_tenants/user_position 经 FK ON DELETE CASCADE 连带清理。

CREATE OR REPLACE FUNCTION sync_user_delete(user_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM users WHERE id = user_id;
END $$;
