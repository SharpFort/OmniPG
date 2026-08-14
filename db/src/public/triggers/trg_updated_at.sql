-- db/src/public/triggers/trg_updated_at.sql
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
        -- PG 不支持 CREATE TRIGGER IF NOT EXISTS（17 号文档归位修正：DO 块守卫幂等）
        IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = format('trg_%s_updated_at', t) AND NOT tgisinternal) THEN
            EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION update_updated_at()', t, t);
        END IF;
    END LOOP;
END;
$$;
