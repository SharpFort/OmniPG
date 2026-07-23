-- db/src/sales/_init_schema.sql
-- =============================================================================
-- Sales Schema 初始化脚本（幂等）
-- 创建 sales Schema 并设置基础权限
-- =============================================================================

-- 1. 创建 Schema（幂等）
CREATE SCHEMA IF NOT EXISTS sales;
COMMENT ON SCHEMA sales IS '销售域 Schema：订单/账单/客户等业务表';

-- 2. 设置 Schema 权限
-- 允许 app_owner 角色使用 sales Schema
GRANT USAGE ON SCHEMA sales TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA sales TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA sales TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA sales TO app_owner;

-- 允许 authenticated 角色使用（PostgREST API 访问）
GRANT USAGE ON SCHEMA sales TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA sales TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sales TO authenticated;
