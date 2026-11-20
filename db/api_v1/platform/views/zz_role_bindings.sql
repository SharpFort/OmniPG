-- db/api_v1/platform/views/zz_role_bindings.sql
-- 种子角色绑定幂等补齐（2026-11-20 收尾批，verify-fresh 冷启动覆盖 071+ 驱动）
--
-- 背景：071_d27c 的超管/租户管理员菜单绑定以 platform.role / tenant_role
--   **投影视图**（apply-src 段产物）为查询源——官方冷启动顺序（迁移先行）
--   执行至此视图未建，071 的 DO 块 undefined_table 容错跳过绑定；演进式部署
--   （apply-src 已跑过）则正常插入。本文件把同一对幂等绑定纳入 apply-src
--   收尾链（views 段 zz_ 排序保证在全部投影重建后执行），保证干净链与
--   演进库的种子绑定终态一致（casbin_rule 视图行集依赖此绑定）。
-- 幂等：ON CONFLICT DO NOTHING 可安全重放；主库演进态已有绑定 → 无副作用。

-- 超管绑定（租户角色菜单，与 071 同款）
DO $$ BEGIN
    INSERT INTO platform.iam_role_menu (menu_id, role_id, created_by)
    SELECT m.id, r.id, 'zz-role-bindings'
    FROM platform.iam_menu m, platform.role r
    WHERE m.id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901' AND r.name = 'role_super_admin'
    ON CONFLICT DO NOTHING;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE 'zz_role_bindings: platform.role 视图未建——超管绑定跳过';
END $$;

-- 租户管理员绑定（只读页面，与 071 同款）
DO $$ BEGIN
    INSERT INTO platform.iam_role_menu (menu_id, org_role_id, created_by)
    SELECT m.id, tr.id, 'zz-role-bindings'
    FROM platform.iam_menu m, platform.tenant_role tr
    WHERE m.id = '019ffbf6-d6d4-7290-8f0d-c7a5e1b4d901' AND tr.name = 'tenant_admin'
    ON CONFLICT DO NOTHING;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE 'zz_role_bindings: platform.tenant_role 视图未建——租户管理员绑定跳过';
END $$;
