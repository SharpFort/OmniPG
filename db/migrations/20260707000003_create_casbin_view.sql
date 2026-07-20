-- ==============================================================================
-- Migration 003: 创建 casbin_rule 视图（Role-in-JWT 优化版，仅 p 规则）
-- ==============================================================================

-- migrate:up

-- ==============================================================================
-- casbin_rule 视图（Role-in-JWT 策略后，仅保留 p 规则）
-- ==============================================================================
-- [修复 P1-1] casbin_rule 视图添加 is_active 过滤
CREATE OR REPLACE VIEW casbin_rule AS
SELECT 
    NULL::integer AS id,
    'p'::varchar AS ptype,
    r.role_code::varchar AS v0,
    a.path::varchar AS v1,
    a.method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM sys_role_api ra
JOIN sys_role r ON ra.role_id = r.id AND r.is_active = true
JOIN sys_api a ON ra.api_id = a.id AND a.is_active = true;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径模式';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法';

-- migrate:down

DROP VIEW IF EXISTS casbin_rule CASCADE;
