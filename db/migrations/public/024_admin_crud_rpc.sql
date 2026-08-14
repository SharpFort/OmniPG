-- =============================================================================
-- 17 号文档归位登记（2026-08-14 仲裁，§6.2）:
--   22 个代码对象（log_operate + 21 RPC）定义段随迁 → src/api_v1 源文件（一文件一对象）:
--     · api_v1_sys.* RPC → db/api_v1/public/rpc/rpc_<name>.sql（终态 schema = api_v1_public）
--     · log_operate → db/src/public/functions/log_operate.sql（终态 038）
--     · v_dict_list/v_user_roles/v_role_users → db/api_v1/public/views/<name>.sql
--     · user_role_read_policy → db/src/public/privileges/rls_policies.sql
--   随迁 GRANT（api_v1_sys.* 版）已删——终态 GRANT 收编各 src 文件尾部（§1 约束 3）
--   保留段: §0 权限点 seed（数据）、§6.5 user_role 表结构、§8 验证 DO 块（引用型，§5）
-- =============================================================================
-- 024_admin_crud_rpc.sql — P1 管理 CRUD RPC（05.2 §六 P1 落地）
-- =============================================================================
-- 背景: 2026-08-04 用户拍板继续 P1
--   部门/岗位/字典/菜单绑定/用户资料 CRUD RPC（7 组）
--   + rpc_get_position_tree（岗位树函数，替代视图方案）
--   + v_dict_list / v_user_roles / v_role_users 视图
--   统一模式: SECURITY DEFINER + has_permission(code) 门槛（42501）
--             + current_tenant_id() 租户校验 + log_operate() 操作审计
-- 权限点 seed: iam_api.api_code（023 加列）+ role_super_admin/tenant_admin 绑定
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 权限点种子（幂等；api_code = has_permission 判定键）
-- ---------------------------------------------------------------------------
INSERT INTO iam_api (api_code, path, method, name, is_active)
SELECT x.api_code, '/rpc/' || x.api_code, 'POST', x.name, true
FROM (VALUES
    ('sys:dept:create',       '部门-新增'),
    ('sys:dept:update',       '部门-修改'),
    ('sys:dept:delete',       '部门-删除'),
    ('sys:position:list',     '岗位-查询'),
    ('sys:position:create',   '岗位-新增'),
    ('sys:position:update',   '岗位-修改'),
    ('sys:position:delete',   '岗位-删除'),
    ('sys:position:assign',   '岗位-分配'),
    ('sys:dict:create',       '字典-新增'),
    ('sys:dict:update',       '字典-修改'),
    ('sys:dict:delete',       '字典-删除'),
    ('sys:menu:create',       '菜单-新增'),
    ('sys:menu:update',       '菜单-修改'),
    ('sys:menu:delete',       '菜单-删除'),
    ('sys:role-api:bind',     '角色API绑定'),
    ('sys:role-menu:bind',    '角色菜单绑定'),
    ('sys:profile:update',    '用户资料-修改'),
    ('sys:tenant:list',       '租户-查询'),
    ('sys:tenant-member:list','租户成员-查询')
) AS x(api_code, name)
ON CONFLICT (path, method) DO NOTHING;

-- 绑定：role_super_admin 全部 + tenant_admin 常用管理项
INSERT INTO iam_role_api (role_code, api_id)
SELECT 'role_super_admin', id FROM iam_api
WHERE api_code IN (SELECT api_code FROM iam_api)
ON CONFLICT (role_code, api_id) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id)
SELECT 'tenant_admin', id FROM iam_api
WHERE api_code IN ('sys:dept:create','sys:dept:update','sys:dept:delete',
                   'sys:position:list','sys:position:create','sys:position:update',
                   'sys:position:delete','sys:position:assign',
                   'sys:dict:create','sys:dict:update','sys:dict:delete',
                   'sys:profile:update')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §1 log_operate — 操作审计统一写入（log_type='operate'；new_data 存详情）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §2 部门 CRUD（department，租户隔离）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §3 岗位 CRUD + 分配 + 树（position / user_position，租户隔离）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §4 字典 CRUD（dict_type / dict_data；全局字典仅超管可写）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §5 菜单/角色绑定管理（iam_menu / iam_role_api / iam_role_menu，平台级）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §6 用户资料（user_profile，动态列白名单模式）
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §6.5 user_role 分配镜像表（05 §6.5 落地：JIT 覆盖 + 主动同步 + 对账）
--     Logto 权威；仅管理端展示，不进授权路径（判定读 claims）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_role (
    user_id    text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_code  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_code)
);
COMMENT ON TABLE user_role IS '用户↔角色分配镜像（Logto 权威；JIT 覆盖+主动同步+对账，05 §6.5；仅管理端展示）';

-- ---------------------------------------------------------------------------
-- §7 视图：v_dict_list / v_user_roles / v_role_users
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §8 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fn int; v_perms int; v_views int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_sys'
        AND p.proname IN ('rpc_create_department','rpc_update_department','rpc_delete_department',
                        'rpc_get_position_tree','rpc_create_position','rpc_update_position',
                        'rpc_delete_position','rpc_assign_user_positions',
                        'rpc_create_dict_type','rpc_update_dict_type','rpc_delete_dict_type',
                        'rpc_create_dict_data','rpc_update_dict_data','rpc_delete_dict_data',
                        'rpc_create_menu','rpc_update_menu','rpc_delete_menu',
                        'rpc_set_role_apis','rpc_set_role_menus',
                        'rpc_get_user_profile','rpc_update_user_profile');
    SELECT count(*) INTO v_perms FROM iam_api WHERE api_code LIKE 'sys:%';
    SELECT count(*) INTO v_views FROM pg_views
      WHERE schemaname='api_v1_sys' AND viewname IN ('v_dict_list','v_user_roles','v_role_users');
    RAISE NOTICE '024: CRUD函数=%（期望21） 权限点=% 视图=%（期望3）', v_fn, v_perms, v_views;
END $$;
