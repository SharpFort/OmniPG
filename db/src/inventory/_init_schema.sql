-- db/src/inventory/_init_schema.sql
-- =============================================================================
-- Inventory Schema 初始化脚本（幂等）
-- 创建 inventory Schema 并设置基础权限
-- =============================================================================

-- 1. 创建 Schema（幂等）
CREATE SCHEMA IF NOT EXISTS inventory;
COMMENT ON SCHEMA inventory IS '库存域 Schema：库存/仓储/物流等业务表';

-- 2. 设置 Schema 权限
-- 允许 app_owner 角色使用 inventory Schema
GRANT USAGE ON SCHEMA inventory TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA inventory TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA inventory TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA inventory TO app_owner;

-- 允许 authenticated 角色使用（PostgREST API 访问）
GRANT USAGE ON SCHEMA inventory TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA inventory TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA inventory TO authenticated;
