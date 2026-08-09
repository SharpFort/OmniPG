-- db/migrations/sys/006_create_sys_config.sql
-- =============================================================================
-- Migration 012: 系统配置中心（预留）
-- =============================================================================

-- migrate:up

-- =============================================================================
-- 系统配置表：存储前端 Logo、站点名称等运行时配置
-- =============================================================================
CREATE TABLE sys_config (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    config_key VARCHAR(100) NOT NULL UNIQUE,
    config_value TEXT,
    config_type VARCHAR(20) NOT NULL DEFAULT 'string',  -- string/number/boolean/json
    description VARCHAR(255),
    is_public BOOLEAN DEFAULT FALSE,  -- 是否前端可见（敏感配置设为 false）
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sys_config IS '系统配置表：存储前端 Logo、站点名称等运行时配置';
COMMENT ON COLUMN sys_config.config_key IS '配置键名（唯一标识）';
COMMENT ON COLUMN sys_config.config_value IS '配置值（统一存文本，按 config_type 解析）';
COMMENT ON COLUMN sys_config.config_type IS '值类型：string/number/boolean/json';
COMMENT ON COLUMN sys_config.is_public IS '是否前端可见（true=前端可读取，false=仅后端）';

CREATE INDEX idx_config_key ON sys_config(config_key);
CREATE INDEX idx_config_public ON sys_config(is_public) WHERE is_public = TRUE;

-- 默认配置
INSERT INTO sys_config (config_key, config_value, config_type, description, is_public) VALUES
('site.title', '零后端权限管理系统', 'string', '站点标题', TRUE),
('site.logo', '/logo.png', 'string', '站点 Logo URL', TRUE),
('site.copyright', '© 2026 OmniPG', 'string', '页脚版权信息', TRUE),
('password.min_length', '8', 'number', '密码最小长度', FALSE),
('password.require_uppercase', 'true', 'boolean', '需要大写字母', FALSE),
('password.require_number', 'true', 'boolean', '需要数字', FALSE),
('password.require_special', 'false', 'boolean', '需要特殊字符', FALSE),
('password.max_age_days', '0', 'number', '密码有效期（0=永不过期）', FALSE),
('password.history_count', '0', 'number', '密码历史记录数（0=不限制）', FALSE),
('session.timeout_minutes', '15', 'number', 'Access Token 有效期（分钟）', FALSE),
('session.max_concurrent', '1', 'number', '单用户最大并发会话数', FALSE),
('security.login_attempts_limit', '5', 'number', '登录失败锁定阈值', FALSE),
('security.lockout_duration_minutes', '30', 'number', '登录锁定时长（分钟）', FALSE)
ON CONFLICT (config_key) DO NOTHING;

-- migrate:down
DROP TABLE IF EXISTS sys_config CASCADE;
