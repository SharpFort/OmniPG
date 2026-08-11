-- db/src/public/views/casbin_rule.sql
-- Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）
-- T7 重写: 自主表 iam_role_api→iam_api + iam_role_menu→iam_menu 投影（05 §6.3 ③）
-- 来源: 20260707000003_create_casbin_view.sql → T7 适配

CREATE OR REPLACE VIEW casbin_rule AS
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    ra.role_code::varchar AS v0,
    a.path::varchar AS v1,
    a.method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_api ra
JOIN iam_api a ON ra.api_id = a.id
WHERE a.is_active
UNION ALL
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    rm.role_code::varchar AS v0,
    m.router::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）：API 路由 + 菜单授权，自动过滤非激活项';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径 / 菜单路径';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法 / menu';
