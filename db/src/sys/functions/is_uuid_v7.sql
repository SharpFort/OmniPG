-- db/src/sys/functions/is_uuid_v7.sql
-- 验证 UUID 是否为 v7 版本（时间有序 UUID）
-- 来源: 02-数据库建模-审计接口与字段模板完整参考-v4.2.md
--
-- UUID v7 结构：
--   xxxxxxxx-xxxx-7xx-xxxx-xxxxxxxxxxxx
--            ↑版本号必须是7
--                     ↑变体位必须是8/9/a/b
--
-- 使用说明：
--   1. 用于 CHECK 约束（允许 NULL）：
--      CHECK (created_by IS NULL OR is_uuid_v7(created_by))
--
--   2. 用于查询验证：
--      SELECT * FROM sys_user WHERE NOT is_uuid_v7(id);
--
--   3. 用于数据质量检查：
--      SELECT count(*) FROM sys_user WHERE created_by IS NOT NULL AND NOT is_uuid_v7(created_by);
--
-- 注意：
--   - 此函数为可选约束，不强制所有表使用
--   - 如需严格验证，请在建表时添加 CHECK 约束
--   - 历史数据迁移时可能需要临时禁用此约束

CREATE OR REPLACE FUNCTION is_uuid_v7(p_uuid uuid)
RETURNS boolean AS $$
BEGIN
    RETURN p_uuid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

COMMENT ON FUNCTION is_uuid_v7(uuid) IS '验证 UUID 是否为 v7 版本（时间有序 UUID）。用于 CHECK 约束或数据质量检查。';
