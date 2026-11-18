-- db/src/platform/functions/write_audit_log.sql
-- 通用审计日志写入函数（供触发器和业务 RPC 调用）
-- D27: audit_log 同时写 tenant_id（Logto 部署租户）与 organization_id（Logto Organization）。

CREATE OR REPLACE FUNCTION platform.write_audit_log(
    p_table_name    text,
    p_operation     text,
    p_old_data      jsonb DEFAULT NULL,
    p_new_data      jsonb DEFAULT NULL,
    p_source        text DEFAULT 'trigger',
    p_description   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_tenant_id text;
    v_organization_id text;
    v_user_id text;
BEGIN
    v_organization_id := COALESCE(
        p_new_data->>'organization_id',
        p_old_data->>'organization_id',
        current_organization_id()
    );
    v_tenant_id := COALESCE(
        p_new_data->>'tenant_id',
        p_old_data->>'tenant_id',
        current_logto_tenant_id()
    );
    v_user_id := current_user_id();

    INSERT INTO platform.audit_log (
        table_name,
        operation,
        old_data,
        new_data,
        user_id,
        tenant_id,
        organization_id,
        source,
        description,
        created_at
    ) VALUES (
        p_table_name,
        p_operation,
        p_old_data,
        p_new_data,
        v_user_id,
        v_tenant_id,
        v_organization_id,
        p_source,
        p_description,
        now()
    );
END;
$$;

COMMENT ON FUNCTION platform.write_audit_log(text, text, jsonb, jsonb, text, text) IS
'通用审计日志写入函数：tenant_id=Logto 部署租户；organization_id=Logto Organization。';
