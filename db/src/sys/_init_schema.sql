-- db/src/sys/_init_schema.sql
-- =============================================================================
-- Schema 初始化脚本（幂等）
-- 创建 sys Schema 并设置基础权限
-- 使用方法：每个新模块都需要一个类似的初始化脚本
-- =============================================================================

-- 1. 创建 Schema（幂等）
CREATE SCHEMA IF NOT EXISTS sys;
COMMENT ON SCHEMA sys IS '权限域 Schema：用户/角色/权限/菜单/审计等核心表';

-- 2. 设置 Schema 权限
-- 禁止 public 角色访问（防止未授权访问）
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- 允许 app_owner 角色使用 sys Schema
GRANT USAGE ON SCHEMA sys TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA sys TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA sys TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA sys TO app_owner;

-- 允许 authenticated 角色使用（PostgREST API 访问）
GRANT USAGE ON SCHEMA sys TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA sys TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sys TO authenticated;
