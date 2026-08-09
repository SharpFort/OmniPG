-- db/src/sys/functions/audit_created_at.sql
-- 强制保护 created_at 字段：INSERT 时强制设为 now()，UPDATE 时禁止修改
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §5（P2 修复）
--
-- 使用说明：
--   CREATE TRIGGER trg_<表名>_audit_created_at
--       BEFORE INSERT OR UPDATE ON <表名>
--       FOR EACH ROW EXECUTE FUNCTION audit_created_at();
--
-- 注意：
--   - INSERT 时：无论应用层传入什么值，都强制覆盖为 now()
--   - UPDATE 时：无论应用层传入什么值，都强制恢复为 OLD.created_at
--   - 这是"最后一道防线"，确保 created_at 不可被应用层篡改

CREATE OR REPLACE FUNCTION audit_created_at()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        NEW.created_at := now();
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.created_at := OLD.created_at;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit_created_at() IS '强制保护 created_at 字段：INSERT 时强制设为 now()，UPDATE 时禁止修改。作为最后一道防线防止应用层篡改。';
