-- db/src/sys/functions/audit_trigger_func.sql
-- 审计触发器函数：使用 write_audit_log() 标准化写入
-- P0 修复：统一审计日志写入接口

CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data jsonb;
    v_new_data jsonb;
BEGIN
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

    -- 使用通用审计函数写入
    PERFORM public.write_audit_log(
        p_table_name := TG_TABLE_NAME,
        p_operation := TG_OP,
        p_old_data := v_old_data,
        p_new_data := v_new_data,
        p_source := 'trigger'
    );

    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION audit_trigger_func() IS '审计触发器函数：使用 write_audit_log() 标准化写入';
