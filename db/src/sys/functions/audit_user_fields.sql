-- db/src/sys/functions/audit_user_fields.sql
-- 自动填充审计用户字段：INSERT 时填充 created_by，UPDATE 时填充 updated_by
-- 来源: 02-数据库建模-Schema触发器与核心逻辑-v4.md §4.2
--
-- 使用说明：
--   CREATE TRIGGER trg_<表名>_audit_user
--       BEFORE INSERT OR UPDATE ON <表名>
--       FOR EACH ROW EXECUTE FUNCTION audit_user_fields();
--
-- 注意：
--   - 当无 JWT 上下文时（如系统任务、pg_cron），current_user_id() 返回全零 UUID
--   - 此时 created_by/updated_by 设为 NULL，表示"系统/匿名创建"
--   - NULL 优于全零 UUID 的原因：
--     1. 语义清晰：NULL = 未知/无用户，全零 UUID 是一个具体值
--     2. 查询方便：WHERE created_by IS NULL 即可找出系统创建的记录
--     3. 聚合准确：COUNT(created_by) 自动忽略 NULL，只统计有明确创建者的记录
--     4. 外键安全：如果 created_by 有外键约束，全零 UUID 会引用不存在的用户

CREATE OR REPLACE FUNCTION audit_user_fields()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        -- 全零 UUID 表示无用户上下文，设为 NULL
        NEW.created_by := NULLIF(current_user_id(), '00000000-0000-0000-0000-000000000000'::uuid);
    ELSIF (TG_OP = 'UPDATE') THEN
        NEW.updated_by := NULLIF(current_user_id(), '00000000-0000-0000-0000-000000000000'::uuid);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit_user_fields() IS '自动填充审计用户字段：INSERT 时填充 created_by，UPDATE 时填充 updated_by。无 JWT 上下文时设为 NULL。';
