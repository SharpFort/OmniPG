-- src/platform/functions/sync_user_suspension.sql
-- FUNCTION: platform.sync_user_suspension（17 号文档归位：迁移 051_logto_guard_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 051_logto_guard_cleanup.sql；幂等写法（§9 模板）
-- 061（2026-08-15）: 镜像表无 updated_at（同步水位统一 logto_updated_at）

CREATE OR REPLACE FUNCTION sync_user_suspension(p_user_id text, p_suspended boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE users
       SET is_suspended   = COALESCE(p_suspended, false),
           logto_updated_at = now()
     WHERE id = p_user_id
       AND (logto_updated_at IS NULL OR now() >= logto_updated_at);
END $$;
