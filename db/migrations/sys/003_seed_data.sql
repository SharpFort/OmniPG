-- ==============================================================================
-- Migration 009: 种子数据（初始管理员、角色、菜单、API）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 步骤 1：Casdoor 集成配置
-- ==============================================================================
INSERT INTO sys_secret (key_name, key_value) VALUES
('casdoor_jwks_url', 'http://casdoor:8000/.well-known/jwks.json')
ON CONFLICT (key_name) DO UPDATE SET key_value = EXCLUDED.key_value;

-- ==============================================================================
-- 步骤 2：默认租户
-- ==============================================================================
INSERT INTO sys_tenant (id, tenant_code, tenant_name, status) VALUES 
('00000000-0000-0000-0000-000000000001', 'default', '默认租户', 'active')
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 步骤 3：默认部门
-- ==============================================================================
INSERT INTO sys_department (id, dept_name, tenant_id) VALUES 
('00000000-0000-0000-0000-000000000002', '默认部门', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 步骤 4：默认管理员用户（密码：admin123，使用 Argon2id 哈希）
-- ==============================================================================
INSERT INTO sys_user (id, username, password_hash, tenant_id, dept_id) VALUES 
(
    '00000000-0000-0000-0000-100000000001',
    'admin',
    generate_user_password('admin123'),
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002'
)
ON CONFLICT (username) DO NOTHING;

-- ==============================================================================
-- 步骤 5：默认角色（全局角色，tenant_id = NULL）
-- ==============================================================================
INSERT INTO sys_role (id, role_code, role_name, tenant_id) VALUES 
('00000000-0000-0000-0000-200000000001', 'super_admin', '超级管理员', NULL),
('00000000-0000-0000-0000-200000000002', 'role_admin', '系统管理员', NULL),
('00000000-0000-0000-0000-200000000003', 'role_editor', '编辑者', NULL),
('00000000-0000-0000-0000-200000000004', 'role_guest', '访客', NULL)
ON CONFLICT (id) DO NOTHING;

-- 将 admin 绑定为超级管理员
INSERT INTO sys_user_role (user_id, role_id, tenant_id) VALUES 
('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000001', '00000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 步骤 6：默认菜单（管理后台基础导航树）
-- ==============================================================================

-- 根目录
INSERT INTO sys_menu (id, parent_id, type, name, path, component, title, icon, sort_order) VALUES
('00000000-0000-0000-0000-300000000001', NULL, 'DIR', 'System', '/system', 'Layout', '系统管理', 'setting', 1)
ON CONFLICT DO NOTHING;

-- 菜单项
INSERT INTO sys_menu (id, parent_id, type, name, path, component, title, icon, sort_order) VALUES
('00000000-0000-0000-0000-300000000002', '00000000-0000-0000-0000-300000000001', 'MENU', 'UserList', 'user', 'system/user/index', '用户管理', 'user', 1),
('00000000-0000-0000-0000-300000000003', '00000000-0000-0000-0000-300000000001', 'MENU', 'RoleList', 'role', 'system/role/index', '角色管理', 'peoples', 2),
('00000000-0000-0000-0000-300000000004', '00000000-0000-0000-0000-300000000001', 'MENU', 'MenuList', 'menu', 'system/menu/index', '菜单管理', 'tree-table', 3),
('00000000-0000-0000-0000-300000000005', '00000000-0000-0000-0000-300000000001', 'MENU', 'ApiList', 'api', 'system/api/index', 'API 管理', 'api', 4)
ON CONFLICT DO NOTHING;

-- 按钮权限
INSERT INTO sys_menu (id, parent_id, type, name, title, permission_code, sort_order) VALUES
('00000000-0000-0000-0000-300000000006', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserAdd', '新增用户', 'user:add', 1),
('00000000-0000-0000-0000-300000000007', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserEdit', '编辑用户', 'user:edit', 2),
('00000000-0000-0000-0000-300000000008', '00000000-0000-0000-0000-300000000002', 'BUTTON', 'UserDelete', '删除用户', 'user:delete', 3)
ON CONFLICT DO NOTHING;

-- 超级管理员默认拥有所有菜单权限
INSERT INTO sys_role_menu (role_id, menu_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_menu
ON CONFLICT DO NOTHING;

-- ==============================================================================
-- 步骤 7：默认 API（PostgREST 基础 CRUD 端点）
-- ==============================================================================

-- 业务表 CRUD API
INSERT INTO sys_api (id, path, method, api_name) VALUES
('00000000-0000-0000-0000-400000000001', '/sys_user', 'GET', '查询用户列表'),
('00000000-0000-0000-0000-400000000002', '/sys_user', 'POST', '新增用户'),
('00000000-0000-0000-0000-400000000003', '/sys_user', 'PATCH', '更新用户'),
('00000000-0000-0000-0000-400000000004', '/sys_user', 'DELETE', '删除用户'),
('00000000-0000-0000-0000-400000000005', '/sys_role', 'GET', '查询角色列表'),
('00000000-0000-0000-0000-400000000006', '/sys_role', 'POST', '新增角色'),
('00000000-0000-0000-0000-400000000007', '/sys_role', 'PATCH', '更新角色'),
('00000000-0000-0000-0000-400000000008', '/sys_role', 'DELETE', '删除角色'),
('00000000-0000-0000-0000-400000000009', '/sys_menu', 'GET', '查询菜单列表'),
('00000000-0000-0000-0000-400000000010', '/sys_menu', 'POST', '新增菜单'),
('00000000-0000-0000-0000-400000000011', '/sys_menu', 'PATCH', '更新菜单'),
('00000000-0000-0000-0000-400000000012', '/sys_menu', 'DELETE', '删除菜单'),
('00000000-0000-0000-0000-400000000013', '/sys_api', 'GET', '查询API列表'),
('00000000-0000-0000-0000-400000000014', '/sys_api', 'POST', '新增API'),
('00000000-0000-0000-0000-400000000015', '/sys_api', 'PATCH', '更新API'),
('00000000-0000-0000-0000-400000000016', '/sys_api', 'DELETE', '删除API')
ON CONFLICT DO NOTHING;

-- RPC 函数 API
INSERT INTO sys_api (id, path, method, api_name) VALUES
('00000000-0000-0000-0000-400000000017', '/rpc/get_user_menu', 'GET', '获取当前用户菜单树'),
('00000000-0000-0000-0000-400000000018', '/rpc/user_login_sso', 'POST', '用户登录'),
('00000000-0000-0000-0000-400000000019', '/rpc/refresh_token_rtr', 'POST', '刷新Token'),
('00000000-0000-0000-0000-400000000020', '/rpc/kick_user', 'POST', '踢用户下线'),
('00000000-0000-0000-0000-400000000021', '/rpc/approve_role_request', 'POST', '审批角色申请')
ON CONFLICT DO NOTHING;

-- 超级管理员拥有所有 API 权限
INSERT INTO sys_role_api (role_id, api_id)
SELECT '00000000-0000-0000-0000-200000000001', id FROM sys_api
ON CONFLICT DO NOTHING;

-- migrate:down
DELETE FROM sys_role_api WHERE role_id = '00000000-0000-0000-0000-200000000001';
DELETE FROM sys_api WHERE id LIKE '00000000-0000-0000-0000-4%';

DELETE FROM sys_role_menu WHERE role_id = '00000000-0000-0000-0000-200000000001';
DELETE FROM sys_menu WHERE id LIKE '00000000-0000-0000-0000-3%';

DELETE FROM sys_user_role WHERE user_id = '00000000-0000-0000-0000-100000000001';
DELETE FROM sys_role WHERE id LIKE '00000000-0000-0000-0000-2%';
DELETE FROM sys_user WHERE id = '00000000-0000-0000-0000-100000000001';
DELETE FROM sys_department WHERE id = '00000000-0000-0000-0000-000000000002';
DELETE FROM sys_tenant WHERE id = '00000000-0000-0000-0000-000000000001';
DELETE FROM sys_secret WHERE key_name = 'casdoor_jwks_url';
