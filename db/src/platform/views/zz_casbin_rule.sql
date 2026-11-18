-- db/src/platform/views/casbin_rule.sql
-- Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）— 055 单表化双段
-- T7 重写: 自主表 iam_role_api→iam_api + iam_role_menu→iam_menu 投影（05 §6.3 ③）
-- 055 重写: API 段数据源改为 iam_role_menu→iam_menu（button 行 api_url/api_method），
--           菜单段（router/'menu'）原样保留——iam_api/iam_role_api 表已删除（D1/D2）
-- D26: iam_role_menu 改 role_id/org_role_id，v0 由全局/租户角色表回卷 role_code。
-- 来源: 20260707000003_create_casbin_view.sql → T7 适配 → 055 单表化

CREATE OR REPLACE VIEW casbin_rule AS
-- API 段（055 单表化：端点随 button 行）
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    COALESCE(r.role_code, tr.name)::varchar AS v0,
    m.api_url::varchar AS v1,
    m.api_method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
LEFT JOIN platform.role r ON r.id = rm.role_id
LEFT JOIN platform.tenant_role tr ON tr.id = rm.org_role_id
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active AND m.api_url IS NOT NULL
UNION ALL
-- 菜单段（原样保留：role_menu → router/'menu'）
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    COALESCE(r.role_code, tr.name)::varchar AS v0,
    m.router::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
LEFT JOIN platform.role r ON r.id = rm.role_id
LEFT JOIN platform.tenant_role tr ON tr.id = rm.org_role_id
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active;

COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（055 双段）：API 段 = role_menu→button 行端点（v1=api_url, v2=api_method）+ 菜单段 = role_menu→router（v2=menu）原样保留；D26 按 role_id/org_role_id 回卷 role_code';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code，由 role_id/org_role_id 回卷）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径 / 菜单路径';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法 / menu';
