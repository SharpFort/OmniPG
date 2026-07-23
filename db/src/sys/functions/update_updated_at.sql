-- db/src/sys/functions/update_updated_at.sql
-- 自动更新 updated_at 字段为当前时间
-- 来源: 20260707000007_create_security_triggers.sql

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION update_updated_at() IS '自动更新 updated_at 字段为当前时间';
