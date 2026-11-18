-- 071_d27c_tenant_role_menu.sql
-- D27c（2026-08-29）：新增「租户角色」只读镜像菜单
-- 背景：tenant_role 视图（Logto organization_roles 镜像）已就绪并 GRANT SELECT
--   TO authenticated，但 iam_menu 无对应菜单行，前端 /system/tenant-role 页面
--   经 get_user_menu 拿不到入口。
-- 内容：
--   1. iam_menu 插入「租户角色」menu 行（父级「只读镜像」目录，order 5，
--      与用户角色 3 / 用户租户 4 同级）；幂等（ON CONFLICT DO NOTHING）。
--   2. 角色绑定：D26 起 iam_role_menu 为 role_id/org_role_id 双列 FK，
--      JWT 角色名先解析为 Logto 角色 ID 再绑定（与 rpc_set_role_menus 同法）。
--      role_super_admin（platform.role.name）与 tenant_admin
--      （platform.tenant_role.name）均可见——只读镜像已授权 authenticated，
--      与「租户」「用户租户」同策略。
-- 前置：066 seed（只读镜像目录行已存在）。
-- migrate:up

INSERT INTO platform.iam_menu
    (id, parent_id, menu_name, router, icon, order_num, is_active, created_at, updated_at,
     created_by, updated_by, menu_type, api_code, component, is_visible, remark, route_name,
     is_link, is_iframe, redirect, is_cache, api_url, api_method, is_affix)
VALUES
    ('019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901',
     '019ffbf6-d66e-7c2a-8c82-4fcaeff70d00',
     '租户角色', '/system/tenant-role', 'ri:shield-user-line', '5', 'true',
     now(), now(), 'd27c-migration', NULL, 'menu', NULL, 'system/tenant-role', 'true',
     NULL, 'TenantRole', 'false', 'false', NULL, 'true', NULL, NULL, 'false')
ON CONFLICT (id) DO NOTHING;

-- 超管绑定（role 镜像表滞后不能走 rpc_set_role_menus 时直接 INSERT；表无 FK 强校验）
INSERT INTO platform.iam_role_menu (menu_id, role_id, created_by)
SELECT m.id, r.id, 'd27c-migration'
FROM platform.iam_menu m, platform.role r
WHERE m.id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901' AND r.name = 'role_super_admin'
ON CONFLICT DO NOTHING;

-- 租户管理员绑定（只读页面，无按钮行）
INSERT INTO platform.iam_role_menu (menu_id, org_role_id, created_by)
SELECT m.id, tr.id, 'd27c-migration'
FROM platform.iam_menu m, platform.tenant_role tr
WHERE m.id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901' AND tr.name = 'tenant_admin'
ON CONFLICT DO NOTHING;

-- migrate:down

DELETE FROM platform.iam_role_menu
WHERE menu_id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901';
DELETE FROM platform.iam_menu
WHERE id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901';
