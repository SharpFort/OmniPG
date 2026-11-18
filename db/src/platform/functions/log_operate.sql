-- src/platform/functions/log_operate.sql
-- FUNCTION: platform.log_operate（D27: 审计日志写入 tenant_id/organization_id 双列）

CREATE OR REPLACE FUNCTION log_operate(p_module text, p_action text, p_target_type text DEFAULT NULL::text, p_target_id text DEFAULT NULL::text, p_result text DEFAULT 'success'::text, p_detail jsonb DEFAULT NULL::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
BEGIN
    INSERT INTO audit_log
        (log_type, operation, module, action, target_type, target_id, result,
         new_data, user_id, tenant_id, organization_id, created_at)
    VALUES
        ('operate', COALESCE(p_action, 'operate'), p_module, p_action,
         p_target_type, p_target_id, p_result,
         p_detail, current_user_id(), current_logto_tenant_id(), current_organization_id(), now());
END;
$$;
