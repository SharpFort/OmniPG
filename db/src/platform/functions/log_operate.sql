-- src/platform/functions/log_operate.sql
-- FUNCTION: platform.log_operate（17 号文档归位：迁移 038_iam_menu_nav_fields.sql 删定义段，本文件为唯一权威）
-- 回放终态: 038_iam_menu_nav_fields.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION log_operate(p_module text, p_action text, p_target_type text DEFAULT NULL::text, p_target_id text DEFAULT NULL::text, p_result text DEFAULT 'success'::text, p_detail jsonb DEFAULT NULL::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
BEGIN
    INSERT INTO audit_log
        (log_type, operation, module, action, target_type, target_id, result,
         new_data, user_id, tenant_id, created_at)
    VALUES
        ('operate', COALESCE(p_action, 'operate'), p_module, p_action,
         p_target_type, p_target_id, p_result,
         p_detail, current_user_id(), current_tenant_id(), now());
END;
$$;
