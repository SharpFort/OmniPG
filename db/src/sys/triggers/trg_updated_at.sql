-- db/src/sys/triggers/trg_updated_at.sql
-- 自动为所有含 updated_at 字段的表创建更新触发器
-- 来源: 20260707000007_create_security_triggers.sql

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN 
        SELECT table_name FROM information_schema.columns 
        WHERE column_name = 'updated_at' AND table_schema = 'public'
    LOOP
        EXECUTE format('CREATE TRIGGER IF NOT EXISTS trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at()', t, t);
    END LOOP;
END;
$$;
