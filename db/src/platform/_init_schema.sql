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

-- 4. super_admin 完全控制（D27 修复：super_admin 原先缺 platform 对象权限，
--    导致 SECURITY INVOKER RPC 内部访问 platform.* 报 42883/42501）
GRANT USAGE ON SCHEMA platform TO super_admin;
GRANT ALL ON ALL TABLES IN SCHEMA platform TO super_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA platform TO super_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA platform TO super_admin;

-- 5. 其它业务角色（role_admin/role_editor/role_guest）只读访问（D27 修复：
--    与 authenticated 同级；写操作统一经 SECURITY DEFINER RPC，无需 platform 表级写权限）
GRANT USAGE ON SCHEMA platform TO role_admin, role_editor, role_guest;
GRANT SELECT ON ALL TABLES IN SCHEMA platform TO role_admin, role_editor, role_guest;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA platform TO role_admin, role_editor, role_guest;
