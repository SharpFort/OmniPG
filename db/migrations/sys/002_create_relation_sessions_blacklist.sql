-- ==============================================================================
-- Migration 002: 关联表 + 会话/黑名单/密钥表
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 9. 用户-角色关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_user_role (
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE,
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE sys_user_role IS '用户-角色关联表';
COMMENT ON COLUMN sys_user_role.tenant_id IS '租户标识，继承自 user 表';
COMMENT ON COLUMN sys_user_role.created_by IS '创建者用户 ID';
CREATE INDEX idx_user_role_tenant ON sys_user_role(tenant_id);

-- ==============================================================================
-- 10. 角色-API 关联表（M:N，网关层 Casbin 数据源）
-- ==============================================================================
CREATE TABLE sys_role_api (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    api_id UUID REFERENCES sys_api(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    PRIMARY KEY (role_id, api_id)
);
COMMENT ON TABLE sys_role_api IS '角色-API 关联表，casbin_rule 视图的 p 规则数据源';
COMMENT ON COLUMN sys_role_api.created_by IS '创建者用户 ID';
CREATE INDEX idx_role_api_api ON sys_role_api(api_id);

-- ==============================================================================
-- 11. 角色-菜单关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_role_menu (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    menu_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES sys_user(id) ON DELETE SET NULL,
    PRIMARY KEY (role_id, menu_id)
);
COMMENT ON TABLE sys_role_menu IS '角色-菜单关联表';
COMMENT ON COLUMN sys_role_menu.created_by IS '创建者用户 ID';
CREATE INDEX idx_role_menu_menu ON sys_role_menu(menu_id);

-- ==============================================================================
-- 12. 用户会话表（Refresh Token 管理，继承 user 的 tenant_id）
-- ==============================================================================
CREATE TABLE sys_user_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES sys_user(id) ON DELETE CASCADE,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    refresh_token_hash VARCHAR(64) NOT NULL UNIQUE,
    active_jti VARCHAR(50),
    is_used BOOLEAN DEFAULT FALSE,
    client_ip VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expired_at TIMESTAMPTZ NOT NULL
);
COMMENT ON TABLE sys_user_session IS '用户会话表，管理 Refresh Token 生命周期';
COMMENT ON COLUMN sys_user_session.tenant_id IS '租户标识，继承自 user 表';
COMMENT ON COLUMN sys_user_session.refresh_token_hash IS 'RT 的 SHA256 哈希（防止泄露）';
COMMENT ON COLUMN sys_user_session.active_jti IS '当前活跃的 Access Token JTI，用于角色变更即时踢下线';
COMMENT ON COLUMN sys_user_session.is_used IS 'RT 是否已被使用（RTR 防重放）';
CREATE INDEX idx_session_user ON sys_user_session(user_id, is_used);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);
CREATE INDEX idx_session_hash ON sys_user_session(refresh_token_hash);
CREATE INDEX idx_session_tenant ON sys_user_session(tenant_id);

-- ==============================================================================
-- 13. Token 黑名单表（含 user_id 关联）
-- ==============================================================================
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY,
    blacklisted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expired_at TIMESTAMPTZ NOT NULL,
    reason VARCHAR(50),
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE
);
COMMENT ON TABLE sys_token_blacklist IS 'Access Token 黑名单，配合 db-pre-request 实现踢下线';
COMMENT ON COLUMN sys_token_blacklist.reason IS '加入黑名单的原因：kicked, role_changed, logout';
COMMENT ON COLUMN sys_token_blacklist.user_id IS '关联用户 ID，便于审计和清理';
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);
CREATE INDEX idx_blacklist_user ON sys_token_blacklist(user_id);

-- ==============================================================================
-- 14. 角色分配审批流表
-- ==============================================================================
CREATE TABLE sys_user_role_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL REFERENCES sys_user(id),
    role_id UUID NOT NULL REFERENCES sys_role(id),
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE RESTRICT,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    applicant_id UUID NOT NULL REFERENCES sys_user(id),
    approver_id UUID REFERENCES sys_user(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    approved_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys_user_role_request IS '角色分配审批流表';
COMMENT ON COLUMN sys_user_role_request.tenant_id IS '租户标识，继承自 user 表';
COMMENT ON COLUMN sys_user_role_request.applicant_id IS '申请人用户 ID';
COMMENT ON COLUMN sys_user_role_request.approver_id IS '审批人用户 ID';
CREATE INDEX idx_role_request_status ON sys_user_role_request(status);
CREATE INDEX idx_role_request_tenant ON sys_user_role_request(tenant_id);
CREATE INDEX idx_role_request_applicant ON sys_user_role_request(applicant_id);

-- migrate:down
DROP TABLE IF EXISTS sys_user_role_request CASCADE;
DROP TABLE IF EXISTS sys_token_blacklist CASCADE;
DROP TABLE IF EXISTS sys_user_session CASCADE;
DROP TABLE IF EXISTS sys_role_menu CASCADE;
DROP TABLE IF EXISTS sys_role_api CASCADE;
DROP TABLE IF EXISTS sys_user_role CASCADE;
