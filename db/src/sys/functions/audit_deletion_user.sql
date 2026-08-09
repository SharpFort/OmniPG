-- db/src/sys/functions/audit_deletion_user.sql
-- 自动填充删除审计字段：deleted_at 从 NULL 变为非 NULL 时填充 deleted_by
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §4.3
--
-- 使用说明：
--   CREATE TRIGGER trg_<表名>_audit_deletion
--       BEFORE UPDATE ON <表名>
--       FOR EACH ROW EXECUTE FUNCTION audit_deletion_user();
--
-- 注意：
--   - 仅在软删除操作（deleted_at 从 NULL → NOT NULL）时触发
--   - 恢复软删除（deleted_at 从 NOT NULL → NULL）时，deleted_by 不会被自动清除
--   - 如需清除，需手动 UPDATE SET deleted_by = NULL

CREATE OR REPLACE FUNCTION audit_deletion_user()
RETURNS TRIGGER AS $$
BEGIN
    IF (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
        NEW.deleted_by := NULLIF(current_user_id(), '00000000-0000-0000-0000-000000000000'::uuid);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit_deletion_user() IS '自动填充删除审计字段：deleted_at 从 NULL 变为非 NULL 时填充 deleted_by。无 JWT 上下文时设为 NULL。';
