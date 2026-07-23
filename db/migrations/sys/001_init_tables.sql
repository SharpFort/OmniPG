-- ==============================================================================
-- Migration 001: 创建基础表（6 张业务表 + 2 张系统表 + 1 个触发器函数）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 0. 扩展启用
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS pg_pwhash;  -- Argon2id 密码哈希
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- sha256 等辅助哈希（仅用于非密码场景）

-- ==============================================================================
-- 1. updated_at 自动更新触发器函数
-- ==============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION update_updated_at() IS '自动更新 updated_at 字段为当前时间';

-- ==============================================================================
-- 2. 密钥配置表（仅 SECURITY DEFINER 函数可读）
-- ==============================================================================
CREATE TABLE sys_secret (
    key_name VARCHAR(100) PRIMARY KEY,
    key_value TEXT NOT NULL
);
COMMENT ON TABLE sys_secret IS '系统密钥存储表，存放 JWT 私钥等敏感配置';
COMMENT ON COLUMN sys_secret.key_name IS '密钥名称';
COMMENT ON COLUMN sys_secret.key_value IS '密钥值（PEM 格式或其他）';

-- ==============================================================================
-- 3. 租户表（多租户管理核心，自引用外键最后添加）
-- ==============================================================================
CREATE TABLE sys_tenant (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    tenant_code VARCHAR(50) NOT NULL UNIQUE,
    tenant_name VARCHAR(100) NOT NULL,
    status tenant_status NOT NULL DEFAULT 'active',
    contact_email VARCHAR(255),
    max_users INT DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 自引用外键：created_by/updated_by/deleted_by 引用 sys_user(id)
    -- 由于 sys_user 外键引用 sys_tenant，这里先不加外键，最后 ALTER TABLE 添加
    created_by UUID,
    updated_by UUID,
    deleted_by UUID
);
COMMENT ON TABLE sys_tenant IS '租户管理表，所有业务数据按租户隔离';
COMMENT ON COLUMN sys_tenant.status IS '租户状态：active=正常, suspended=暂停, disabled=禁用';
COMMENT ON COLUMN sys_tenant.max_users IS '该租户最大用户数限制';
COMMENT ON COLUMN sys_tenant.created_by IS '创建者用户 ID（最后 ALTER TABLE 添加 FK）';
COMMENT ON COLUMN sys_tenant.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_tenant.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_tenant_code ON sys_tenant(tenant_code);
CREATE INDEX idx_tenant_status ON sys_tenant(status);

-- ==============================================================================
-- 4. 部门表（支持树形结构，租户隔离）
-- ==============================================================================
CREATE TABLE sys_department (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    dept_name VARCHAR(100) NOT NULL,
    tenant_id UUID NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    parent_id UUID REFERENCES sys_department(id) ON DELETE CASCADE,
    sort_order INT DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 审计字段
    created_by UUID,
    updated_by UUID,
    deleted_by UUID
);
COMMENT ON TABLE sys_department IS '部门组织架构表，按租户隔离';
COMMENT ON COLUMN sys_department.tenant_id IS '所属租户，租户间部门数据隔离';
COMMENT ON COLUMN sys_department.parent_id IS '上级部门 ID，NULL 表示根部门';
COMMENT ON COLUMN sys_department.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_department.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_department.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_dept_tenant ON sys_department(tenant_id);
CREATE INDEX idx_dept_parent ON sys_department(parent_id);

-- ==============================================================================
-- 5. 用户表（含租户和部门字段）
-- ==============================================================================
CREATE TABLE sys_user (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    tenant_id UUID NOT NULL REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    dept_id UUID REFERENCES sys_department(id) ON DELETE SET NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 审计字段（自引用外键最后 ALTER TABLE 添加）
    created_by UUID,
    updated_by UUID,
    deleted_by UUID
);
COMMENT ON TABLE sys_user IS '用户表，含多租户和部门关联';
COMMENT ON COLUMN sys_user.tenant_id IS '租户标识，用于多租户行级隔离';
COMMENT ON COLUMN sys_user.dept_id IS '所属部门，用于数据级权限过滤';
COMMENT ON COLUMN sys_user.password_hash IS 'Argon2id 哈希值（pg_pwhash 生成）';
COMMENT ON COLUMN sys_user.is_active IS '账户是否激活（软删除替代字段）';
COMMENT ON COLUMN sys_user.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_user.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_user.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_user_tenant_dept ON sys_user(tenant_id, dept_id);
CREATE INDEX idx_user_username ON sys_user(username);
CREATE INDEX idx_user_tenant ON sys_user(tenant_id);

-- ==============================================================================
-- 6. 角色表（支持全局角色 + 租户角色）
-- ==============================================================================
CREATE TABLE sys_role (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    role_code VARCHAR(50) NOT NULL,
    role_name VARCHAR(100) NOT NULL,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 审计字段
    created_by UUID,
    updated_by UUID,
    deleted_by UUID,
    -- 租户角色的 role_code 在租户内唯一（tenant_id 有值时）
    CONSTRAINT uq_role_code_tenant UNIQUE (role_code, tenant_id)
);
COMMENT ON TABLE sys_role IS '角色表：tenant_id=NULL 为全局角色，有值为租户角色';
COMMENT ON COLUMN sys_role.tenant_id IS 'NULL=全局角色（所有租户可见），有值=租户私有角色';
COMMENT ON COLUMN sys_role.role_code IS '角色代码（英文标识），写入 JWT 的 roles 数组';
COMMENT ON COLUMN sys_role.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_role.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_role.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_role_code ON sys_role(role_code);
CREATE INDEX idx_role_tenant ON sys_role(tenant_id);
-- 全局角色（tenant_id NULL）的 role_code 全局唯一（PostgreSQL 唯一约束中 NULL != NULL，所以用部分唯一索引）
CREATE UNIQUE INDEX idx_role_code_global ON sys_role(role_code) WHERE tenant_id IS NULL;

-- ==============================================================================
-- 7. API 资源表（后端权限防御对象，系统级共享）
-- ==============================================================================
CREATE TABLE sys_api (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    path VARCHAR(255) NOT NULL,
    method VARCHAR(10) NOT NULL,
    api_name VARCHAR(100),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 审计字段
    created_by UUID,
    updated_by UUID,
    deleted_by UUID,
    CONSTRAINT uq_api_path_method UNIQUE (path, method)
);
COMMENT ON TABLE sys_api IS 'API 资源表，定义后端接口的边界防御规则（系统级共享）';
COMMENT ON COLUMN sys_api.path IS 'API 路径模式，支持 :id 通配符';
COMMENT ON COLUMN sys_api.method IS 'HTTP 方法：GET/POST/PUT/DELETE/PATCH';
COMMENT ON COLUMN sys_api.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_api.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_api.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_api_path_method ON sys_api(path, method);

-- ==============================================================================
-- 8. 菜单与前端权限标识表（系统级共享）
-- ==============================================================================
CREATE TABLE sys_menu (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    parent_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    type menu_type NOT NULL,
    name VARCHAR(100) NOT NULL,
    path VARCHAR(255),
    component VARCHAR(255),
    title VARCHAR(100) NOT NULL,
    icon VARCHAR(100),
    permission_code VARCHAR(100),
    sort_order INT DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    -- 审计字段
    created_by UUID,
    updated_by UUID,
    deleted_by UUID
);
COMMENT ON TABLE sys_menu IS '菜单与前端权限表：DIR=目录, MENU=页面菜单, BUTTON=按钮（系统级共享）';
COMMENT ON COLUMN sys_menu.component IS '前端组件路径，如 system/user/index';
COMMENT ON COLUMN sys_menu.permission_code IS '按钮权限标识，如 user:add，仅 type=BUTTON 时使用';
COMMENT ON COLUMN sys_menu.created_by IS '创建者用户 ID';
COMMENT ON COLUMN sys_menu.updated_by IS '最后修改者用户 ID';
COMMENT ON COLUMN sys_menu.deleted_by IS '删除者用户 ID';
CREATE INDEX idx_menu_parent ON sys_menu(parent_id);
CREATE INDEX idx_menu_type ON sys_menu(type);

-- ==============================================================================
-- 9. 添加自引用外键约束（必须在所有表创建完成后）
-- ==============================================================================
-- sys_tenant 自引用外键
ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_tenant ADD CONSTRAINT fk_tenant_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- sys_user 自引用外键
ALTER TABLE sys_user ADD CONSTRAINT fk_user_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_user ADD CONSTRAINT fk_user_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_user ADD CONSTRAINT fk_user_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- sys_department 审计字段外键
ALTER TABLE sys_department ADD CONSTRAINT fk_dept_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_department ADD CONSTRAINT fk_dept_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_department ADD CONSTRAINT fk_dept_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- sys_role 审计字段外键
ALTER TABLE sys_role ADD CONSTRAINT fk_role_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_role ADD CONSTRAINT fk_role_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_role ADD CONSTRAINT fk_role_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- sys_api 审计字段外键
ALTER TABLE sys_api ADD CONSTRAINT fk_api_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_api ADD CONSTRAINT fk_api_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_api ADD CONSTRAINT fk_api_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- sys_menu 审计字段外键
ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_created_by FOREIGN KEY (created_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_updated_by FOREIGN KEY (updated_by) REFERENCES sys_user(id) ON DELETE SET NULL;
ALTER TABLE sys_menu ADD CONSTRAINT fk_menu_deleted_by FOREIGN KEY (deleted_by) REFERENCES sys_user(id) ON DELETE SET NULL;

-- migrate:down
DROP TABLE IF EXISTS sys_menu CASCADE;
DROP TABLE IF EXISTS sys_api CASCADE;
DROP TABLE IF EXISTS sys_role CASCADE;
DROP TABLE IF EXISTS sys_user CASCADE;
DROP TABLE IF EXISTS sys_department CASCADE;
DROP TABLE IF EXISTS sys_secret CASCADE;
DROP TABLE IF EXISTS sys_tenant CASCADE;
DROP FUNCTION IF EXISTS update_updated_at();
