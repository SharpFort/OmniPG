-- =============================================================================
-- rebuild_iam_menu_20260814_bind.sql — 角色绑定（绕过 rpc_set_role_menus 校验）
-- 背景: rpc_set_role_menus 校验 role 镜像表存在角色，而 role 表仅同步了
--   role_auditor/citywalk-user（033 已知滞后）；role_super_admin 虽在 Logto
--   但未镜像，tenant_admin 是 Logto 组织角色（organization_roles）永远不会
--   进 user-level role 镜像表 —— 与 055 §4.5 同法直接 INSERT（表无 FK 到 role）
-- =============================================================================
SET request.jwt.claims = '{"sub":"menu-rebuild-2026-08-14","roles":["role_super_admin"]}';

INSERT INTO public.iam_role_menu (role_code, menu_id, created_by)
SELECT 'role_super_admin', m.id, 'menu-rebuild-2026-08-14'
FROM public.iam_menu m
ON CONFLICT (role_code, menu_id) DO NOTHING;

INSERT INTO public.iam_role_menu (role_code, menu_id, created_by)
SELECT 'tenant_admin', m.id, 'menu-rebuild-2026-08-14'
FROM public.iam_menu m
WHERE (m.menu_type IN ('directory','menu')
       AND m.menu_name NOT IN ('用户角色','登录日志','应用配置'))
   OR (m.menu_type = 'button'
       AND m.api_code NOT IN (
           'public:user:list','public:role-menu:bind','public:data-scope:bind',
           'public:menu:create','public:menu:update','public:menu:delete',
           'public:login-log:list','public:config:write','public:import'))
ON CONFLICT (role_code, menu_id) DO NOTHING;

-- 验证
SELECT 'bind_super' AS k, count(*)::text AS v FROM public.iam_role_menu WHERE role_code='role_super_admin'
UNION ALL SELECT 'bind_tenant', count(*)::text FROM public.iam_role_menu WHERE role_code='tenant_admin'
UNION ALL SELECT 'tenant_menus', count(*)::text FROM public.iam_role_menu rm
    JOIN public.iam_menu m ON m.id=rm.menu_id
    WHERE rm.role_code='tenant_admin' AND m.menu_type IN ('directory','menu')
UNION ALL SELECT 'tenant_buttons', count(*)::text FROM public.iam_role_menu rm
    JOIN public.iam_menu m ON m.id=rm.menu_id
    WHERE rm.role_code='tenant_admin' AND m.menu_type='button';
