-- db/src/public/functions/audit_user_fields.sql
-- 自动填充审计用户字段：INSERT 时填充 created_by，UPDATE 时填充 updated_by
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §4.2（v4.5：_by 字段 TEXT 化，对齐 Logto 用户 id）
--
-- 使用说明：
--   CREATE TRIGGER trg_<表名>_audit_user
--       BEFORE INSERT OR UPDATE ON <表名>
--       FOR EACH ROW EXECUTE FUNCTION audit_user_fields();
--
-- 注意：
--   - current_user_id() 读取 JWT claims 的 sub（Logto 用户 id，text）
--   - 无 JWT 上下文时（系统任务、pg_cron、webhook 同步）返回 NULL → _by 置 NULL
--   - NULL 语义：系统/同步/匿名操作；查询 WHERE created_by IS NULL；COUNT 自动忽略
--   - _by 不建外键：镜像表用户会随 Logto 物理删除，FK 会破坏审计留痕

CREATE OR REPLACE FUNCTION audit_user_fields()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        NEW.created_by := current_user_id();
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.updated_by := current_user_id();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit_user_fields() IS '自动填充审计用户字段：INSERT 时填充 created_by，UPDATE 时填充 updated_by。无 JWT 上下文时设为 NULL（Logto 用户 id，text）。';
