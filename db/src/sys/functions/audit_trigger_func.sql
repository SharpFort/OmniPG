-- db/src/sys/functions/audit_trigger_func.sql
-- 审计触发器函数：记录 INSERT/UPDATE/DELETE 操作到 sys_audit_log
-- 来源: 20260707000012_audit_triggers.sql

CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data jsonb;
    v_new_data jsonb;
    v_tenant_id uuid;
BEGIN
    IF TG_NARGS > 0 AND TG_ARGV[0] = 'tenant_aware' THEN
        IF (TG_OP = 'DELETE') THEN
            v_tenant_id := OLD.tenant_id;
        ELSE
            v_tenant_id := NEW.tenant_id;
        END IF;
    END IF;

    IF (TG_OP = 'DELETE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
    ELSIF (TG_OP = 'INSERT') THEN
        v_old_data := NULL;
        v_new_data := to_jsonb(NEW);
    ELSIF (TG_OP = 'UPDATE') THEN
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
    END IF;

    INSERT INTO sys_audit_log (
        table_name, operation, old_data, new_data, user_id, tenant_id, created_at
    ) VALUES (
        TG_TABLE_NAME, TG_OP, v_old_data, v_new_data, current_user_id(), v_tenant_id, now()
    );

    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION audit_trigger_func() IS '审计触发器函数：记录 INSERT/UPDATE/DELETE 操作到 sys_audit_log';
