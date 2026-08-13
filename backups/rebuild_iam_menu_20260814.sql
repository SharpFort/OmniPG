-- =============================================================================
-- rebuild_iam_menu_20260814.sql — 菜单清空重建（055 单表化模型 + 后端控制模式）
-- 依据: docs/5.菜单初始化-前端页面分类与入库方案.md（用户已审查确认）
-- 执行: SET claims 模拟超管 → TRUNCATE → rpc_create_menu 逐行建树 → 角色绑定
-- 备份: backups/iam_menu_20260814_before_rebuild.sql
-- =============================================================================

-- 模拟超管 JWT（rpc_create_menu / rpc_set_role_menus 门槛短路）
SET request.jwt.claims = '{"sub":"menu-rebuild-2026-08-14","roles":["role_super_admin"]}';

-- 清空（iam_role_menu 由 CASCADE 连带清空）
TRUNCATE TABLE public.iam_role_menu;
TRUNCATE TABLE public.iam_menu CASCADE;

-- -----------------------------------------------------------------------------
-- §1 建树（rpc_create_menu 返回 {ok, id}，逐级捕获 id 作父级）
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v json;
    v_dash   uuid;  -- 仪表盘
    v_mirror uuid;  -- 只读镜像
    v_sys    uuid;  -- 系统管理
    v_log    uuid;  -- 日志管理
    v_res    uuid;  -- 结果页面
    v_exc    uuid;  -- 异常页面
    v_id     uuid;
BEGIN
    -- ================= 1. 仪表盘 =================
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '仪表盘', p_menu_type => 'directory',
        p_icon => 'ri:pie-chart-line', p_order_num => 0) INTO v;
    v_dash := (v->>'id')::uuid;

    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '工作台', p_menu_type => 'menu', p_parent_id => v_dash,
        p_router => '/dashboard/console', p_route_name => 'Console',
        p_component => 'dashboard/console', p_icon => 'ri:dashboard-line',
        p_order_num => 0) INTO v;

    -- ================= 2. 只读镜像 =================
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '只读镜像', p_menu_type => 'directory',
        p_icon => 'ri:eye-line', p_order_num => 1) INTO v;
    v_mirror := (v->>'id')::uuid;

    -- 2.1 用户数据
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '用户数据', p_menu_type => 'menu', p_parent_id => v_mirror,
        p_router => '/system/user', p_route_name => 'User',
        p_component => 'system/user', p_icon => 'ri:user-3-line',
        p_order_num => 0) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '用户列表', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:user:list', p_api_url => '/rpc/search_users',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '用户资料-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:profile:update', p_api_url => '/rpc/rpc_update_user_profile',
        p_api_method => 'POST', p_order_num => 1);

    -- 2.2 角色
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '角色', p_menu_type => 'menu', p_parent_id => v_mirror,
        p_router => '/system/role', p_route_name => 'Role',
        p_component => 'system/role', p_icon => 'ri:team-line',
        p_order_num => 1) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '角色菜单绑定', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:role-menu:bind', p_api_url => '/rpc/rpc_set_role_menus',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '数据范围-绑定', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:data-scope:bind', p_api_url => '/rpc/rpc_set_role_data_scope',
        p_api_method => 'POST', p_order_num => 1);

    -- 2.3 租户
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '租户', p_menu_type => 'menu', p_parent_id => v_mirror,
        p_router => '/system/tenant', p_route_name => 'Tenant',
        p_component => 'system/tenant', p_icon => 'ri:building-line',
        p_order_num => 2) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '租户-查询', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:tenant:list', p_api_url => '/rpc/rpc_list_tenants',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '租户成员-查询', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:tenant-member:list', p_api_url => '/rpc/rpc_list_tenant_members',
        p_api_method => 'POST', p_order_num => 1);

    -- 2.4 用户角色（仅超管：v_user_roles 034 不授 authenticated）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '用户角色', p_menu_type => 'menu', p_parent_id => v_mirror,
        p_router => '/system/user-role', p_route_name => 'UserRole',
        p_component => 'system/user-role', p_icon => 'ri:user-star-line',
        p_order_num => 3) INTO v;

    -- 2.5 用户租户
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '用户租户', p_menu_type => 'menu', p_parent_id => v_mirror,
        p_router => '/system/user-tenant', p_route_name => 'UserTenant',
        p_component => 'system/user-tenant', p_icon => 'ri:user-settings-line',
        p_order_num => 4) INTO v;

    -- ================= 3. 系统管理 =================
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '系统管理', p_menu_type => 'directory',
        p_icon => 'ri:user-3-line', p_order_num => 2) INTO v;
    v_sys := (v->>'id')::uuid;

    -- 3.1 部门管理
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '部门管理', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/dept', p_route_name => 'Dept',
        p_component => 'system/dept', p_icon => 'ri:git-branch-line',
        p_order_num => 0) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '部门-新增', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dept:create', p_api_url => '/rpc/rpc_create_department',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '部门-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dept:update', p_api_url => '/rpc/rpc_update_department',
        p_api_method => 'POST', p_order_num => 1);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '部门-删除', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dept:delete', p_api_url => '/rpc/rpc_delete_department',
        p_api_method => 'POST', p_order_num => 2);

    -- 3.2 岗位管理
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '岗位管理', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/position', p_route_name => 'Position',
        p_component => 'system/position', p_icon => 'ri:briefcase-2-line',
        p_order_num => 1) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '岗位-查询', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:position:list', p_api_url => '/rpc/rpc_get_position_tree',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '岗位-新增', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:position:create', p_api_url => '/rpc/rpc_create_position',
        p_api_method => 'POST', p_order_num => 1);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '岗位-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:position:update', p_api_url => '/rpc/rpc_update_position',
        p_api_method => 'POST', p_order_num => 2);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '岗位-删除', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:position:delete', p_api_url => '/rpc/rpc_delete_position',
        p_api_method => 'POST', p_order_num => 3);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '岗位-分配', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:position:assign', p_api_url => '/rpc/rpc_assign_user_positions',
        p_api_method => 'POST', p_order_num => 4);

    -- 3.3 用户岗位
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '用户岗位', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/user-position', p_route_name => 'UserPosition',
        p_component => 'system/user-position', p_icon => 'ri:user-follow-line',
        p_order_num => 2) INTO v;

    -- 3.4 字典类型
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '字典类型', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/dict', p_route_name => 'Dict',
        p_component => 'system/dict', p_icon => 'ri:book-3-line',
        p_order_num => 3) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典类型-新增', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:create', p_api_url => '/rpc/rpc_create_dict_type',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典类型-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:update', p_api_url => '/rpc/rpc_update_dict_type',
        p_api_method => 'POST', p_order_num => 1);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典类型-删除', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:delete', p_api_url => '/rpc/rpc_delete_dict_type',
        p_api_method => 'POST', p_order_num => 2);

    -- 3.5 字典数据
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '字典数据', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/dict-data', p_route_name => 'DictData',
        p_component => 'system/dict-data', p_icon => 'ri:file-list-3-line',
        p_order_num => 4) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典数据-新增', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:create', p_api_url => '/rpc/rpc_create_dict_data',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典数据-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:update', p_api_url => '/rpc/rpc_update_dict_data',
        p_api_method => 'POST', p_order_num => 1);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '字典数据-删除', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:dict:delete', p_api_url => '/rpc/rpc_delete_dict_data',
        p_api_method => 'POST', p_order_num => 2);

    -- 3.6 菜单管理（route_name 手填 Menus——056 推导会得 Menu）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '菜单管理', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/menu', p_route_name => 'Menus',
        p_component => 'system/menu', p_icon => 'ri:menu-line',
        p_order_num => 5) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '菜单-新增', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:menu:create', p_api_url => '/rpc/rpc_create_menu',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '菜单-修改', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:menu:update', p_api_url => '/rpc/rpc_update_menu',
        p_api_method => 'POST', p_order_num => 1);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '菜单-删除', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:menu:delete', p_api_url => '/rpc/rpc_delete_menu',
        p_api_method => 'POST', p_order_num => 2);

    -- 3.7 系统监控
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '系统监控', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/monitor', p_route_name => 'Monitor',
        p_component => 'system/monitor', p_icon => 'ri:monitor-line',
        p_order_num => 6) INTO v;

    -- 3.8 应用配置（敏感：仅超管）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '应用配置', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/app-config', p_route_name => 'AppConfig',
        p_component => 'system/app-config', p_icon => 'ri:settings-3-line',
        p_order_num => 7) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '配置-写入', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:config:write', p_api_url => '/rpc/update_config',
        p_api_method => 'POST', p_order_num => 0);
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '数据-导入', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:import', p_api_url => '/rpc/import_csv',
        p_api_method => 'POST', p_order_num => 1);

    -- 3.9 定时任务日志
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '定时任务日志', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/cron-job-log', p_route_name => 'CronJobLog',
        p_component => 'system/cron-job-log', p_icon => 'ri:time-line',
        p_order_num => 8) INTO v;

    -- 3.10 日志管理（子目录）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '日志管理', p_menu_type => 'directory', p_parent_id => v_sys,
        p_icon => 'ri:file-chart-line', p_order_num => 9) INTO v;
    v_log := (v->>'id')::uuid;

    -- 3.10.1 登录日志（仅超管）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '登录日志', p_menu_type => 'menu', p_parent_id => v_log,
        p_router => '/system/login-log', p_route_name => 'LoginLog',
        p_component => 'system/login-log', p_icon => 'ri:login-box-line',
        p_order_num => 0) INTO v;
    v_id := (v->>'id')::uuid;
    PERFORM api_v1_public.rpc_create_menu(
        p_menu_name => '登录日志-查询', p_menu_type => 'button', p_parent_id => v_id,
        p_api_code => 'public:login-log:list', p_api_url => '/rpc/rpc_search_login_logs',
        p_api_method => 'POST', p_order_num => 0);

    -- 3.10.2 审计日志
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '审计日志', p_menu_type => 'menu', p_parent_id => v_log,
        p_router => '/system/audit-log', p_route_name => 'AuditLog',
        p_component => 'system/audit-log', p_icon => 'ri:file-search-line',
        p_order_num => 1) INTO v;

    -- 3.11 个人中心（隐藏页：任何用户仅能访问自己的；is_visible=false）
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '个人中心', p_menu_type => 'menu', p_parent_id => v_sys,
        p_router => '/system/user-center', p_route_name => 'UserCenter',
        p_component => 'system/user-center', p_icon => 'ri:user-smile-line',
        p_is_visible => false, p_order_num => 10) INTO v;

    -- ================= 4. 结果页面 =================
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '结果页面', p_menu_type => 'directory',
        p_icon => 'ri:checkbox-circle-line', p_order_num => 3) INTO v;
    v_res := (v->>'id')::uuid;

    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '成功页', p_menu_type => 'menu', p_parent_id => v_res,
        p_router => '/result/success', p_route_name => 'ResultSuccess',
        p_component => 'result/success', p_icon => 'ri:checkbox-circle-line',
        p_order_num => 0) INTO v;
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '失败页', p_menu_type => 'menu', p_parent_id => v_res,
        p_router => '/result/fail', p_route_name => 'ResultFail',
        p_component => 'result/fail', p_icon => 'ri:close-circle-line',
        p_order_num => 1) INTO v;

    -- ================= 5. 异常页面 =================
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '异常页面', p_menu_type => 'directory',
        p_icon => 'ri:error-warning-line', p_order_num => 4) INTO v;
    v_exc := (v->>'id')::uuid;

    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '403', p_menu_type => 'menu', p_parent_id => v_exc,
        p_router => '/exception/403', p_route_name => 'Exception403',
        p_component => 'exception/403', p_icon => 'ri:forbid-line',
        p_order_num => 0) INTO v;
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '404', p_menu_type => 'menu', p_parent_id => v_exc,
        p_router => '/exception/404', p_route_name => 'Exception404',
        p_component => 'exception/404', p_icon => 'ri:file-unknow-line',
        p_order_num => 1) INTO v;
    SELECT api_v1_public.rpc_create_menu(
        p_menu_name => '500', p_menu_type => 'menu', p_parent_id => v_exc,
        p_router => '/exception/500', p_route_name => 'Exception500',
        p_component => 'exception/500', p_icon => 'ri:bug-line',
        p_order_num => 2) INTO v;
END $$;

-- -----------------------------------------------------------------------------
-- §2 角色绑定（rpc_set_role_menus 全量覆盖）
--   role_super_admin: 全量菜单+按钮
--   tenant_admin: 目录/菜单行排除 用户角色/登录日志/应用配置；
--                 按钮行排除 超管专属（user:list 也排除——前端用户页走 v_user_list 视图 GET）
-- -----------------------------------------------------------------------------
SELECT api_v1_public.rpc_set_role_menus('role_super_admin',
    ARRAY(SELECT id FROM public.iam_menu ORDER BY order_num));

SELECT api_v1_public.rpc_set_role_menus('tenant_admin',
    ARRAY(
        SELECT m.id FROM public.iam_menu m
        WHERE m.menu_type IN ('directory','menu')
          AND m.menu_name NOT IN ('用户角色','登录日志','应用配置')
        UNION
        SELECT m.id FROM public.iam_menu m
        WHERE m.menu_type = 'button'
          AND m.api_code NOT IN (
              'public:user:list','public:role-menu:bind','public:data-scope:bind',
              'public:menu:create','public:menu:update','public:menu:delete',
              'public:login-log:list','public:config:write','public:import')
    ));

-- -----------------------------------------------------------------------------
-- §3 验证输出
-- -----------------------------------------------------------------------------
SELECT 'menu_total' AS k, count(*)::text AS v FROM public.iam_menu
UNION ALL
SELECT 'menu_root', count(*)::text FROM public.iam_menu WHERE parent_id IS NULL
UNION ALL
SELECT 'button_total', count(*)::text FROM public.iam_menu WHERE menu_type='button'
UNION ALL
SELECT 'bind_super', count(*)::text FROM public.iam_role_menu WHERE role_code='role_super_admin'
UNION ALL
SELECT 'bind_tenant', count(*)::text FROM public.iam_role_menu WHERE role_code='tenant_admin';
