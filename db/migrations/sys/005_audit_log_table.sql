-- ==============================================================================
-- Migration 011: 审计日志表
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- 审计日志表：记录所有关键业务表的数据变更
-- ==============================================================================
CREATE TABLE sys_audit_log (
    id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    operation audit_operation NOT NULL,
    old_data JSONB,
    new_data JSONB,
    user_id UUID,
    tenant_id UUID REFERENCES sys_tenant(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE sys_audit_log IS '数据变更审计日志，记录 INSERT/UPDATE/DELETE 操作';
COMMENT ON COLUMN sys_audit_log.old_data IS '变更前的数据（DELETE 时保存被删除的数据）';
COMMENT ON COLUMN sys_audit_log.new_data IS '变更后的数据（INSERT 时保存新数据）';
COMMENT ON COLUMN sys_audit_log.user_id IS '操作人用户 ID';
COMMENT ON COLUMN sys_audit_log.tenant_id IS '租户标识';
CREATE INDEX idx_audit_table ON sys_audit_log(table_name);
CREATE INDEX idx_audit_tenant ON sys_audit_log(tenant_id);
CREATE INDEX idx_audit_created ON sys_audit_log(created_at);
CREATE INDEX idx_audit_user ON sys_audit_log(user_id);

-- migrate:down
DROP TABLE IF EXISTS sys_audit_log CASCADE;
