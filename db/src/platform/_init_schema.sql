-- db/src/platform/_init_schema.sql
-- =============================================================================
-- 系统管理模块 Schema 权限设置（幂等）
-- 
-- 注意：业务核心对象已迁入 platform schema（40 号方案：Logto 留 public，业务迁出）
-- 本脚本仅设置权限，不创建新 Schema
-- =============================================================================

-- 1. 设置 platform Schema 权限
-- 禁止 PUBLIC 角色访问（防止未授权访问）
REVOKE ALL ON SCHEMA platform FROM PUBLIC;

-- 2. 允许 app_owner 角色使用 platform Schema 中的业务对象
GRANT USAGE ON SCHEMA platform TO app_owner;
GRANT ALL ON ALL TABLES IN SCHEMA platform TO app_owner;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA platform TO app_owner;
GRANT ALL ON ALL SEQUENCES IN SCHEMA platform TO app_owner;

-- 3. 允许 authenticated 角色使用（PostgREST API 访问）
GRANT USAGE ON SCHEMA platform TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA platform TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA platform TO authenticated;
