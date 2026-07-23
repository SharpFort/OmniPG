-- db/fixtures/sys/default_users.sql
-- 测试数据集：默认用户数据（用于初始化测试环境）
-- ⚠️ 仅在测试环境通过 seed-data.sh 加载

-- 默认租户
INSERT INTO sys_tenant (id, tenant_code, tenant_name, status) VALUES 
('00000000-0000-0000-0000-000000000001', 'default', '默认租户', 'active')
ON CONFLICT (id) DO NOTHING;

-- 默认部门
INSERT INTO sys_department (id, dept_name, tenant_id) VALUES 
('00000000-0000-0000-0000-000000000002', '默认部门', '00000000-0000-0000-0000-000000000001')
ON CONFLICT (id) DO NOTHING;

-- 默认角色
INSERT INTO sys_role (id, role_code, role_name, description, is_active) VALUES 
('00000000-0000-0000-0000-000000000010', 'role_admin', '系统管理员', '系统管理角色', TRUE),
('00000000-0000-0000-0000-000000000011', 'role_guest', '访客', '只读访问角色', TRUE)
ON CONFLICT (id) DO NOTHING;
