-- db/api_v1/public/views/v_user_list.sql
-- 用户列表视图：含租户名、部门名（T7: tenants 镜像 + 成员关系；无角色绑定镜像）
-- 来源: 20260707000015_system_management_api.sql → T7 适配 → 058 +name 列
-- 058: +name——前端用户页关键词搜索 or=(username.ilike, email.ilike, name.ilike) 依赖
-- 061: 镜像表无 updated_at/deleted_at——updated_at 映射 logto_updated_at、deleted_at 恒 NULL（列集稳定）

CREATE OR REPLACE VIEW api_v1_public.v_user_list AS
SELECT
    u.id,
    u.username,
    u.primary_email AS email,
    u.primary_phone AS phone,
    u.name,
    p.tenant_id,
    p.dept_id,
    t.name AS tenant_name,
    d.dept_name,
    (NOT u.is_suspended) AS is_active,
    u.created_at,
    u.logto_updated_at AS updated_at,     -- 061: 同步水位
    NULL::timestamptz AS deleted_at,      -- 061: 镜像表无软删，恒 NULL
    COALESCE(
        (SELECT json_agg(ut.organization_id ORDER BY ut.organization_id)
         FROM public.user_tenants ut
         WHERE ut.user_id = u.id),
        '[]'::json
    ) AS organizations
FROM public.users u
LEFT JOIN public.user_profile p ON p.user_id = u.id
LEFT JOIN public.tenants t ON p.tenant_id = t.id
LEFT JOIN public.department d ON p.dept_id = d.id;
COMMENT ON VIEW api_v1_public.v_user_list IS '用户列表视图（058 +name 列：前端关键词搜索姓名匹配；061 updated_at=同步水位、deleted_at 恒 NULL；含租户名、部门名、组织成员关系）';
