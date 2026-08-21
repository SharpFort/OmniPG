-- src/platform/functions/sync_role_delete.sql
-- FUNCTION: platform.sync_role_delete（17 号文档归位：迁移 016_role_rename.sql 删定义段，本文件为唯一权威）
-- 回放终态: 016_role_rename.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION platform.sync_role_delete(role_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    DELETE FROM role WHERE id = role_id;
END $$;
