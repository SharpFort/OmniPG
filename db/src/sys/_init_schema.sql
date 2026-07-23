-- db/src/sys/_init_schema.sql
-- =============================================================================
-- 系统管理模块 Schema 权限设置（幂等）
-- 
-- 注意：sys 模块保持在 public Schema 中（存量模块不迁移）
-- 本脚本仅设置权限，不创建新 Schema
-- =============================================================================

-- 1. 设置 public Schema 权限
-- 禁止 public 角色访问（防止未授权访问）
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- 2. 允许 app_owner 角色使用 public Schema 中的 sys 模块对象
GRANT USAGE ON SCHEMA public TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app_owner;

-- 3. 允许 authenticated 角色使用（PostgREST API 访问）
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
