-- =============================================================================
-- 035_rpc_cleanup_unify.sql — 前端对齐方案 §1.2/§2.2 RPC 层修复
-- =============================================================================
-- 背景: 2026-08-07 前端对齐后端方案审查（§1.2 RPC 清单 B4-B7 + §2.2 API 层审查）
--   P1-B5: health_check 删除（20260707000014_auth_rpc_functions 遗留，全库无引用；
--           健康检查由 APISIX upstream / Pigsty 监控承担）
--   P1-B5: export_csv 删除（半成品：返回提示文本而非数据；SECURITY DEFINER +
--           p_columns/p_filter 裸 SQL 拼接 = 注入面；PostgREST 不支持流式 COPY，
--           导出走 GET /api_v1_public/{view}?select=... 原生能力（RLS 生效））
--   P1-B6: rpc_sync_user_roles 删除（Logto 官方 webhook 事件表核实：
--           User.*/Role.*/Organization.* 无"用户-角色绑定"事件（PUT /users/:id/roles
--           不触发任何 hook）→ 无法靠 Logto 推送；JIT 覆盖并入 ensure_user——
--           登录时 JWT claims roles 即 Logto 权威快照，随登录链路自动对齐，
--           前端零额外调用，业务端无主动同步）
--   P1-B5: import_csv 安全重写（原白名单 = api_v1_public 全部视图 - 3 个排除，
--           含镜像投影视图 role/user_role（简单视图可更新，DEFINER 可写穿
--           Logto 镜像表）；且值拼接无引号 = SQL 注入面 + JSON null 错位）
--           → 显式业务表白名单 + jsonb_populate_record 参数化列子集插入
--   P2-B4: search_users / search_audit_log 补 LIMIT 上限（原无上限）
--   P2-B4: 分页上限统一 100（rpc_search_login_logs 1000 / rpc_list_tenants 200 /
--           rpc_list_tenant_members 500 → 100；页面 10-50 条 + offset 翻页足够；
--           RPC 返回单一 JSON payload，PostgREST 无法对其 Range 分页，
--           自带 p_limit/p_offset 是唯一正确模式；GET /view 才用 PostgREST 原生分页）
--   P2-B6: tenant_admin 补绑 sys:tenant:list / sys:tenant-member:list（租户仅查看；
--           login-log 保持超管专属——030 绑定；用户/角色查看走 RLS 无门槛）
--   统一门槛三档: 新增 src 层 require_permission(text) / require_super_admin()
--           无门槛（INVOKER+RLS）/ 权限点（DEFINER+require_permission）/
--           超管（DEFINER+require_super_admin）——本轮重写函数应用，其余渐进
-- ⚠️ §2.2 审查补丁（同迁移追加）:
--   P0: get_user_permissions 删除（uuid 变量接收 text nanoid 调用必炸 22P02；
--       Casdoor 时代残留，三个输出均有替代：roles→get_current_user、
--       权限码→v_role_api_detail、菜单→get_user_menu；casbin_rule 视图保留——
--       pgTAP 测试引用，只读兼容视图无害）
--   P1: cleanup_expired_tokens 整链删除（死链：public.cleanup_expired_tokens()
--       全库无定义（029 wrapper 内部 PERFORM 目标不存在）；清理对象
--       sys_token_blacklist/sys_user_session 014 已删（D12 会话/吊销交 Logto）——
--       无可清理之物，cron 任务 cleanup-expired-tokens 一并删除（034 重调度作废）
--   P1: get_dept_tree(p_tenant_id) uuid → text（017 department.tenant_id text 化后
--       参数未同步；传值调用 text=uuid 无隐式 cast 必炸，传 NULL 短路不炸）
--   P1: rpc_list_cron_jobs/runs 补 GRANT authenticated（021 只授 web_anon，
--       与全库惯例不一致，authenticated 角色调用 42501）
--   P2: get_user_menu() 增加 menu_type 列（前端 §2.4 需过滤 button 菜单项，
--       原返回无此列无法区分；033 回填的按钮项会混入路由注册）
-- 联动: 024 删 sys:user-role:sync seed、025 删 §1 rpc_sync_user_roles、
--       029 删 §3 export_csv + §4 cleanup_expired_tokens + sys:export/sys:session:cleanup
--       seed、034 删 cleanup-expired-tokens 重调度段（源文件已改；已执行环境本迁移
--       DROP IF EXISTS / cron.unschedule 兜底，重放后不复活）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 统一权限门槛 helper（src 层 db/src/public/functions/ 同款；此处保险重建）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §2 删除废弃 RPC（030 先例：废弃功能直接删，防 apply-src 重放复活）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.health_check();
DROP FUNCTION IF EXISTS api_v1_public.export_csv(text, text, text);
DROP FUNCTION IF EXISTS api_v1_public.rpc_sync_user_roles(text);
DROP FUNCTION IF EXISTS api_v1_public.get_user_permissions();          -- §2.2 补丁 P0
DROP FUNCTION IF EXISTS api_v1_public.cleanup_expired_tokens();        -- §2.2 补丁 P1（死链）
DROP FUNCTION IF EXISTS api_v1_sys.cleanup_expired_tokens();           -- §2.2 补丁 P1（重放兜底）

-- 权限点清理（sys:export/sys:user-role:sync 已无函数、sys:session:cleanup 已无函数）
DELETE FROM iam_role_api
WHERE api_id IN (SELECT id FROM iam_api
                 WHERE api_code IN ('sys:export', 'sys:user-role:sync', 'sys:session:cleanup'));
DELETE FROM iam_api
WHERE api_code IN ('sys:export', 'sys:user-role:sync', 'sys:session:cleanup');

-- §2.2 补丁 P1：删除 cleanup-expired-tokens 定时任务（死链：无底层函数、无清理对象；
-- 034 重调度作废；cleanup-old-audit-logs 保留）
DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-expired-tokens');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时忽略（pg_cron 扩展未装等）
END $$;

-- ---------------------------------------------------------------------------
-- §3 import_csv 安全重写
--     显式白名单：仅业务自主表（可批量导入）；镜像/审计/日志/绑定表排除
--     参数化：jsonb_populate_record 单行插入（类型安全、列名安全、JSON null → NULL）
--     保留: sys:import 门槛 + dry_run + per-row 错误收集 + log_operate
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §4 search_users / search_audit_log 补 LIMIT 上限（原无上限，p_limit 可传任意大）
--     RPC 分页模式: 自带 p_limit/p_offset（PostgREST 无法对 RPC 结果 Range 分页）
--     上限统一 100: 页面 10-50 条，offset 翻页；防误传大 limit 拉全表
-- ---------------------------------------------------------------------------






-- ---------------------------------------------------------------------------
-- §5 rpc_search_login_logs 重写（023 版 + 上限统一 100；DEFINER + 权限点档）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §6 rpc_list_tenants / rpc_list_tenant_members 重写（025 版 + 上限统一 100）
-- ---------------------------------------------------------------------------






-- ---------------------------------------------------------------------------
-- §7 ensure_user 增加 user_role 分配镜像 JIT 覆盖
--     登录链路（前端回调调 ensure_user）即 Logto 权威推送（JWT claims roles），
--     替代 rpc_sync_user_roles（035 删除）；未登录用户数据陈旧由 P2 对账任务可选兜底
--     N7（2026-08-11）: users/profile 改为"仅缺失补建、不覆盖 webhook 权威值"
--     （旧版空串覆盖 username/name/avatar、profile tenant_id 随组织 token 漂移、
--      is_suspended 不受 JIT 管理）——见 §7 函数体注释
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §8 tenant_admin 补绑租户查看权限点（B6：项目段租户仅查看）
--     登录日志（sys:login-log:list）保持超管专属（030 绑定）
-- ---------------------------------------------------------------------------
INSERT INTO iam_role_api (role_code, api_id)
SELECT 'tenant_admin', id FROM iam_api
WHERE api_code IN ('sys:tenant:list', 'sys:tenant-member:list')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §9 §2.2 补丁：rpc_list_cron_jobs/runs 补 GRANT authenticated
--     021 只授 web_anon（全库孤例）；authenticated 角色调用 42501；
--     超管门槛在函数内部（is_super_admin），此处只需执行权限
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §10 §2.2 补丁：get_dept_tree 参数 uuid → text
--     017 把 department.tenant_id 改 text 后参数未同步；传值调用
--     text = uuid 无隐式 cast 必炸（传 NULL 时 OR 短路不炸，掩盖问题）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §11 §2.2 补丁：get_user_menu() 增加 menu_type/perms/is_visible/component 列
--     前端 §2.4 需按 menu_type 过滤 button 按钮项（033 回填的按钮项
--     若绑定进 iam_role_menu 会混入路由注册）；原返回无此列无法区分。
--     035 补丁（用户拍板 2026-08-07）：+component 列——033 已回填
--     path→组件路径（regexp_replace(path,'^/','')||'/index'），但原返回
--     不下发 → 前端只能靠 11 项硬编码映射表，新菜单必改前端代码；
--     补列后前端映射表降级为兜底（component 为空时用）。
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §12 §2.5/§2.6 审查补丁（2026-08-07 用户拍板）
--   A. is_super_admin() 重建（P0）：030 只重建 current_user_roles()，is_super_admin
--      仍是 Casdoor 旧版（isGlobalAdmin/isAdmin claim + roles[].name 对象数组语义）→
--      Logto roles 字符串数组下 r->>'name' 恒 NULL → 恒 false → RLS 超管豁免 /
--      has_permission 短路 / rpc_search_login_logs 超管分支全线失效
--      （功能面被 011"超管绑全部权限点"掩盖）。重建 = current_user_roles() @>
--      ARRAY['role_super_admin']（030 注释声称的意图）
--   B. rpc_create_menu 增加 p_is_visible（业界实践对齐：RuoYi/Admin.NET 系新增菜单
--      表单均含显示状态字段、创建时一次提交；原签名无此参数 → 新建默认可见、
--      隐藏需二次 update_menu；iam_menu.is_visible 列 022 已存在，无需改表）
--   C. v_role_users JOIN 键清晰化（ur.role_code = r.name → r.role_code；
--      role_code 为 name 生成列故原写法碰巧正确，防未来语义变化踩坑）
-- ---------------------------------------------------------------------------








-- ---------------------------------------------------------------------------
-- §13 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_deleted    int;   -- 已删函数残留（期望 0 = 不存在）
    v_perms      int;   -- 残留权限点（期望 0）
    v_import     int;   -- import_csv 安全特征（期望 2: require_permission + jsonb_populate_record）
    v_limits     int;   -- LIMIT 上限函数数（期望 5: search_users/search_audit_log/login_logs/tenants/members）
    v_jit        int;   -- ensure_user JIT 特征（期望 1）
    v_tenant_bind int;  -- tenant_admin 租户权限点绑定数（期望 2）
    v_helper     int;   -- helper 函数数（期望 2）
    v_dept_param int;   -- get_dept_tree 参数 text 化（期望 1）
    v_menu_type  int;   -- get_user_menu 含 menu_type（期望 1）
    v_cron_grant int;   -- cron RPC authenticated 可执行（期望 2）
    v_cron_cleanup int; -- cleanup-expired-tokens 任务残留（期望 0）
    v_super      boolean; -- is_super_admin Logto 语义（期望 true）
    v_create_menu int;  -- rpc_create_menu 含 p_is_visible（期望 1）
    v_role_users int;   -- v_role_users JOIN 键清晰化（期望 1）
BEGIN
    SELECT count(*) INTO v_deleted FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('health_check','export_csv','rpc_sync_user_roles',
                        'get_user_permissions','cleanup_expired_tokens');
    SELECT count(*) INTO v_perms FROM iam_api
      WHERE api_code IN ('sys:export','sys:user-role:sync','sys:session:cleanup');
    SELECT count(*) INTO v_import FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'import_csv'
        AND prosrc LIKE '%require_permission%'
        AND prosrc LIKE '%jsonb_populate_record%';
    SELECT count(*) INTO v_limits FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('search_users','search_audit_log','rpc_search_login_logs',
                        'rpc_list_tenants','rpc_list_tenant_members')
        AND prosrc LIKE '%LEAST(p_limit, 100)%';
    SELECT count(*) INTO v_jit FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'ensure_user'
        AND prosrc LIKE '%user_role%';
    SELECT count(*) INTO v_tenant_bind FROM iam_role_api ra
      JOIN iam_api a ON a.id = ra.api_id
      WHERE ra.role_code = 'tenant_admin'
        AND a.api_code IN ('sys:tenant:list','sys:tenant-member:list');
    SELECT count(*) INTO v_helper FROM pg_proc
      WHERE proname IN ('require_permission','require_super_admin');
    SELECT count(*) INTO v_dept_param FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_public' AND p.proname = 'get_dept_tree'
        AND pg_get_function_arguments(p.oid) LIKE '%text%';
    SELECT count(*) INTO v_menu_type FROM pg_proc
      WHERE proname = 'get_user_menu'
        AND prosrc LIKE '%menu_type%';
    SELECT count(*) INTO v_cron_grant FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_public'
        AND p.proname IN ('rpc_list_cron_jobs','rpc_list_cron_job_runs')
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
    SELECT count(*) INTO v_cron_cleanup FROM cron.job
      WHERE jobname = 'cleanup-expired-tokens';
    -- §12 补丁断言（035 追加）
    -- 环境自适应（17 号文档：is_super_admin 已归位 src，dbmate up 阶段不存在则跳过）
    IF to_regprocedure('is_super_admin()') IS NOT NULL THEN
        SELECT is_super_admin() INTO v_super;
    END IF;
    SELECT count(*) INTO v_create_menu FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'rpc_create_menu'
        AND pg_get_function_arguments(oid) LIKE '%is_visible%';
    SELECT count(*) INTO v_role_users FROM pg_views
      WHERE schemaname = 'api_v1_public' AND viewname = 'v_role_users';
    RAISE NOTICE '035: 已删函数残留=%（期望0） 权限点残留=%（期望0） import安全特征=%（期望2） LIMIT上限函数=%（期望5） ensure_user_JIT=%（期望1） tenant_admin绑定=%（期望2） helper=%（期望2） dept参数text=%（期望1） menu含menu_type=%（期望1） cron授权=%（期望2） cleanup任务残留=%（期望0） is_super_admin=%（迁移上下文无claims应为false，true分支由PGlite行为断言覆盖） create_menu含is_visible=%（期望1） v_role_users存在=%（期望1）',
        v_deleted, v_perms, v_import, v_limits, v_jit, v_tenant_bind, v_helper,
        v_dept_param, v_menu_type, v_cron_grant, v_cron_cleanup, v_super,
        v_create_menu, v_role_users;
    -- is_super_admin 断言（Logto 语义；无 claims 时验证块本身以匿名身份跑 → 应为 false，
    -- 由 PGlite 行为断言覆盖 true 分支）
    IF v_super THEN
        RAISE WARNING '035: is_super_admin() 为 true——验证块在特权上下文执行，跳过期望检查';
    END IF;
END $$;
