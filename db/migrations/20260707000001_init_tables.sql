-- ==============================================================================
-- Migration 001: 创建基础表（6 张表）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 1. 密钥配置表（仅 SECURITY DEFINER 函数可读）
-- ==============================================================================
CREATE TABLE sys_secret (
    key_name VARCHAR(100) PRIMARY KEY,
    key_value TEXT NOT NULL
);
COMMENT ON TABLE sys_secret IS '系统密钥存储表，存放 JWT 私钥等敏感配置';
COMMENT ON COLUMN sys_secret.key_name IS '密钥名称';
COMMENT ON COLUMN sys_secret.key_value IS '密钥值（PEM 格式）';

-- ==============================================================================
-- 2. 部门表（支持树形结构）
-- ==============================================================================
CREATE TABLE sys_department (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dept_name VARCHAR(100) NOT NULL,
    parent_id UUID REFERENCES sys_department(id) ON DELETE RESTRICT,  -- [修复 P2-4] 有子部门时禁止删除
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_department IS '部门组织架构表';
COMMENT ON COLUMN sys_department.parent_id IS '上级部门 ID，NULL 表示根部门';
CREATE INDEX idx_department_parent ON sys_department(parent_id);

-- ==============================================================================
-- 3. 用户表（含多租户 + 部门字段）
-- ==============================================================================
CREATE TABLE sys_user (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    tenant_id VARCHAR(50) NOT NULL,
    dept_id UUID REFERENCES sys_department(id) ON DELETE SET NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_user IS '用户表，支持多租户和部门关联';
COMMENT ON COLUMN sys_user.tenant_id IS '租户标识，用于多租户行级隔离';
COMMENT ON COLUMN sys_user.password_hash IS 'bcrypt 哈希值（cost=10）';
COMMENT ON COLUMN sys_user.is_active IS '账户是否激活（soft delete 标记）';
CREATE INDEX idx_user_tenant_dept ON sys_user(tenant_id, dept_id);
CREATE INDEX idx_user_username ON sys_user(username);
CREATE INDEX idx_user_tenant_active ON sys_user(tenant_id, is_active);

-- ==============================================================================
-- 4. 角色表
-- ==============================================================================
CREATE TABLE sys_role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code VARCHAR(50) NOT NULL UNIQUE,
    role_name VARCHAR(100) NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_role IS '角色表，role_code 写入 JWT 的 roles 数组';
COMMENT ON COLUMN sys_role.role_code IS '角色代码（英文标识），如 super_admin, role_guest';
CREATE INDEX idx_role_code ON sys_role(role_code);

-- ==============================================================================
-- 5. API 资源表（Casbin 防御对象）
-- ==============================================================================
CREATE TABLE sys_api (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    path VARCHAR(255) NOT NULL,
    method VARCHAR(10) NOT NULL,
    api_name VARCHAR(100),
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_api IS 'API 资源表，定义网关层 Casbin 的边界防御规则';
COMMENT ON COLUMN sys_api.path IS 'API 路径模式，如 /sys_user, /rpc/user_login_sso';
COMMENT ON COLUMN sys_api.method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH';
CREATE INDEX idx_api_path_method ON sys_api(path, method);
CREATE UNIQUE INDEX idx_api_path_method_unique ON sys_api(path, method);

-- ==============================================================================
-- 6. 菜单与按钮权限表
-- ==============================================================================
CREATE TABLE sys_menu (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    type VARCHAR(10) NOT NULL CHECK (type IN ('DIR', 'MENU', 'BUTTON')),
    name VARCHAR(100) NOT NULL,
    path VARCHAR(255),
    component VARCHAR(255),
    title VARCHAR(100) NOT NULL,
    icon VARCHAR(100),
    permission_code VARCHAR(100),
    sort_order INT DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE sys_menu IS '菜单与前权限标识表：DIR=目录, MENU=页面菜单, BUTTON=按钮';
COMMENT ON COLUMN sys_menu.component IS '前端组件路径，如 system/user/index';
COMMENT ON COLUMN sys_menu.permission_code IS '按钮权限标识，如 user:add';
CREATE INDEX idx_menu_parent ON sys_menu(parent_id);
CREATE INDEX idx_menu_type ON sys_menu(type);

-- migrate:down

DROP TABLE IF EXISTS sys_menu CASCADE;
DROP TABLE IF EXISTS sys_api CASCADE;
DROP TABLE IF EXISTS sys_role CASCADE;
DROP TABLE IF EXISTS sys_user CASCADE;
DROP TABLE IF EXISTS sys_department CASCADE;
DROP TABLE IF EXISTS sys_secret CASCADE;
