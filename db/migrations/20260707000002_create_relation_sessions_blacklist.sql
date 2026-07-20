-- ==============================================================================
-- Migration 002: 关联表 + 会话/黑名单表
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 7. 用户-角色关联表（M:N）
-- ==============================================================================
CREATE TABLE sys_user_role (
    user_id UUID REFERENCES sys_user(id) ON DELETE CASCADE,
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, role_id)
);
COMMENT ON TABLE sys_user_role IS '用户-角色关联表';
CREATE INDEX idx_user_role_role ON sys_user_role(role_id);

-- ==============================================================================
-- 8. 角色-API 关联表（Casbin p 规则数据源）
-- ==============================================================================
CREATE TABLE sys_role_api (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    api_id UUID REFERENCES sys_api(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (role_id, api_id)
);
COMMENT ON TABLE sys_role_api IS '角色-API 关联表，casbin_rule 视图的 p 规则数据源';
CREATE INDEX idx_role_api_api ON sys_role_api(api_id);

-- ==============================================================================
-- 9. 角色-菜单关联表
-- ==============================================================================
CREATE TABLE sys_role_menu (
    role_id UUID REFERENCES sys_role(id) ON DELETE CASCADE,
    menu_id UUID REFERENCES sys_menu(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (role_id, menu_id)
);
COMMENT ON TABLE sys_role_menu IS '角色-菜单关联表';
CREATE INDEX idx_role_menu_menu ON sys_role_menu(menu_id);

-- ==============================================================================
-- 10. 用户会话表（Refresh Token 管理）
-- ==============================================================================
CREATE TABLE sys_user_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES sys_user(id) ON DELETE CASCADE,
    refresh_token_hash VARCHAR(64) NOT NULL UNIQUE,
    active_jti VARCHAR(50),
    is_used BOOLEAN DEFAULT FALSE,
    client_ip VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL
);
COMMENT ON TABLE sys_user_session IS '用户会话表，管理 Refresh Token 生命周期';
COMMENT ON COLUMN sys_user_session.refresh_token_hash IS 'RT 的 SHA256 哈希（防止泄露）';
COMMENT ON COLUMN sys_user_session.active_jti IS '当前活跃的 AT jti，用于角色变更即时踢下线';
COMMENT ON COLUMN sys_user_session.is_used IS 'RT 是否已被使用（RTR 防重放）';
CREATE INDEX idx_session_user ON sys_user_session(user_id, is_used);
CREATE INDEX idx_session_expiry ON sys_user_session(expired_at);
CREATE INDEX idx_session_hash ON sys_user_session(refresh_token_hash);

-- ==============================================================================
-- 11. Token 黑名单表
-- ==============================================================================
CREATE TABLE sys_token_blacklist (
    jti VARCHAR(50) PRIMARY KEY,
    blacklisted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expired_at TIMESTAMP WITH TIME ZONE NOT NULL,
    reason VARCHAR(100)
);
COMMENT ON TABLE sys_token_blacklist IS 'Access Token 黑名单，配合 db-pre-request 实现踢下线';
COMMENT ON COLUMN sys_token_blacklist.reason IS '加入黑名单的原因：role_change, logout, kicked';
CREATE INDEX idx_blacklist_expired ON sys_token_blacklist(expired_at);

-- migrate:down

DROP TABLE IF EXISTS sys_token_blacklist CASCADE;
DROP TABLE IF EXISTS sys_user_session CASCADE;
DROP TABLE IF EXISTS sys_role_menu CASCADE;
DROP TABLE IF EXISTS sys_role_api CASCADE;
DROP TABLE IF EXISTS sys_user_role CASCADE;
