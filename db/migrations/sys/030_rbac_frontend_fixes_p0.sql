-- =============================================================================
-- 030_rbac_frontend_fixes_p0.sql — 前端反馈 P0 三项修复
-- =============================================================================
-- 背景: 2026-08-05 前端联调反馈（已代码级核实）
--   P0-1: current_user_roles() 按 Casdoor 对象数组解析，Logto roles 是字符串数组
--         → is_super_admin() 恒 false → RLS 超管豁免 / has_permission 短路 /
--         rpc_search_login_logs 超管分支全线失效（核心缺陷）
--   P0-2: rpc_get_online_users 引用悬空视图 v_online_users（全库无定义）→ 调用必报错
--         （在线用户功能 05.1 已定稿不需要，Logto 会话管理替代）
--   P0-3: sys:login-log:list 权限点未 seed（024 只 seed 20 个）→ rpc_search_login_logs
--         非超管永远 42501
-- 幂等: CREATE OR REPLACE / DROP IF EXISTS / ON CONFLICT；apply-src 重放安全
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 current_user_roles() 重建（Logto 字符串数组语义）
--     is_super_admin() = current_user_roles() @> ARRAY['role_super_admin'] 立即恢复
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_roles() RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(current_setting('request.jwt.claims', true)::jsonb -> 'roles', '[]'::jsonb)
        )
    );
$$;
COMMENT ON FUNCTION current_user_roles() IS '当前用户角色 code 列表（JWT claims roles 字符串数组，零查询；030 修复 Logto 语义）';

-- ---------------------------------------------------------------------------
-- §2 删除 rpc_get_online_users（悬空引用 v_online_users；在线用户功能废弃）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.get_online_users(int, int);
DROP FUNCTION IF EXISTS api_v1_public.get_online_users();

-- ---------------------------------------------------------------------------
-- §3 seed sys:login-log:list（rpc_search_login_logs 门槛权限点，023 引用）
--     仅超管绑定（登录日志敏感，租户维度查询经 rpc 内 user_tenants 过滤）
-- ---------------------------------------------------------------------------
INSERT INTO iam_api (api_code, path, method, name, is_active)
SELECT 'sys:login-log:list', '/rpc/sys:login-log:list', 'POST', '登录日志-查询', true
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id)
SELECT 'role_super_admin', id FROM iam_api WHERE api_code = 'sys:login-log:list'
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §4 验证（claims 模拟：Logto 字符串数组）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_roles  text[];
    v_super  boolean;
    v_perm   int;
    v_fn     int;
BEGIN
    -- 模拟 Logto JWT：roles = 字符串数组
    PERFORM set_config('request.jwt.claims',
                       '{"sub":"u_test","roles":["role_super_admin","tenant_admin"]}', true);

    SELECT current_user_roles() INTO v_roles;
    SELECT is_super_admin() INTO v_super;

    RAISE NOTICE '030: current_user_roles()=%（期望 {role_super_admin,tenant_admin}）', v_roles;
    RAISE NOTICE '030: is_super_admin()=%（期望 true）', v_super;

    SELECT count(*) INTO v_perm FROM iam_api WHERE api_code = 'sys:login-log:list';
    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace AND proname = 'get_online_users';

    IF v_roles IS DISTINCT FROM ARRAY['role_super_admin','tenant_admin'] THEN
        RAISE EXCEPTION '030 验证失败: current_user_roles 解析错误';
    END IF;
    IF NOT v_super THEN
        RAISE EXCEPTION '030 验证失败: is_super_admin 未恢复';
    END IF;
    IF v_perm <> 1 THEN
        RAISE EXCEPTION '030 验证失败: sys:login-log:list 未 seed';
    END IF;
    IF v_fn <> 0 THEN
        RAISE EXCEPTION '030 验证失败: get_online_users 未删除';
    END IF;
    RAISE NOTICE '030: 全部验证通过（is_super_admin 恢复 / 权限点 seed / 悬空 RPC 已删）';
END $$;
