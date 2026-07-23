-- db/api_v1/sys/views/v_role_api_detail.sql
-- 角色-API 关联详情视图（Casbin p 规则数据源）
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE VIEW api_v1_sys.v_role_api_detail AS
SELECT 
    ra.role_id,
    ra.api_id,
    ra.created_at,
    r.role_code,
    r.role_name,
    a.path,
    a.method,
    a.api_name,
    a.is_active AS api_is_active
FROM public.sys_role_api ra
JOIN public.sys_role r ON ra.role_id = r.id
JOIN public.sys_api a ON ra.api_id = a.id
WHERE r.deleted_at IS NULL AND a.deleted_at IS NULL;
COMMENT ON VIEW api_v1_sys.v_role_api_detail IS '角色-API 关联详情视图（Casbin p 规则数据源）';
