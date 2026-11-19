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
    -- 入参校验（2026-11-19 修复）：列宽限制提前拦截，避免裸 22001/23502 触发器级报错
    IF p_operation IS NULL OR p_operation = '' THEN
        RAISE EXCEPTION 'p_operation required' USING ERRCODE = '22023';
    END IF;
    IF length(p_operation) > 50 THEN
        RAISE EXCEPTION 'p_operation exceeds audit_log.operation varchar(50)' USING ERRCODE = '22001';
    END IF;
    IF p_table_name IS NOT NULL AND length(p_table_name) > 100 THEN
        RAISE EXCEPTION 'p_table_name exceeds audit_log.table_name varchar(100)' USING ERRCODE = '22001';
    END IF;
    IF p_source IS NOT NULL AND length(p_source) > 20 THEN
        RAISE EXCEPTION 'p_source exceeds audit_log.source varchar(20)' USING ERRCODE = '22001';
    END IF;
    -- 审计归因必须以会话上下文为准，行数据仅作系统写入（无 claims）时的回退，
    -- 防止调用方通过写入行内的 tenant_id/organization_id 伪造跨租户审计归属
    v_organization_id := COALESCE(
        current_organization_id(),
        p_new_data->>'organization_id',
        p_old_data->>'organization_id'
    );
    v_tenant_id := COALESCE(
        -- strict 优先：有 claim 用 claim；无 claim（系统任务/webhook）回退行数据；
        -- 兜底 'default' 保持系统行可写（compat getter 永不返回 NULL，无法承担"无上下文"语义）
        current_logto_tenant_id_strict(),
        p_new_data->>'tenant_id',
        p_old_data->>'tenant_id',
        'default'
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
REVOKE ALL ON FUNCTION platform.write_audit_log(text, text, jsonb, jsonb, text, text) FROM PUBLIC;

COMMENT ON FUNCTION platform.write_audit_log(text, text, jsonb, jsonb, text, text) IS
'通用审计日志写入函数：tenant_id=Logto 部署租户；organization_id=Logto Organization；归因以会话上下文优先（行数据仅回退）。';
