-- =============================================================================
-- 043_iam_api_crud_rpc.sql — API 权限点写 RPC（新增/编辑/删除，P0，2026-08-09）
-- =============================================================================
-- 背景: 前端 §5.2「新增/编辑 API 表单」待办（OmniAdmin 对接清单 3. 后端038-042，
--       第 5 节）：API 管理页目前只读（iam_api 视图列表），后端 038-042 无
--       rpc_create_api/rpc_update_api → 做表单必然 404。本迁移补齐写 RPC。
-- 决策:
--   D1 三个写 RPC: rpc_create_api / rpc_update_api / rpc_delete_api（与管理页
--       菜单 CRUD 三件套对齐；删除时存在角色绑定则拒绝——039 D3 死端点保留
--       同理，避免 CASCADE 静默清掉 55 条 role_api 绑定）
--   D2 新权限点: sys:api:create / sys:api:update / sys:api:delete（024/029/042
--       惯例命名），仅绑 role_super_admin（菜单/API 目录为平台级——与
--       sys:menu:* 同域，tenant_admin 不授）
--   D3 归属菜单/分组: create 时 p_api_group 为空但给了 p_menu_id → 默认取
--       归属菜单名（表单"分组默认随菜单名"服务端落地，前端免预取菜单名）；
--       update 不做自动派生（表单两字段均回显，显式提交）
--   D4 清空语义（表单可取消归属/清空分组/清空描述）: 文本字段传 '' → NULL；
--       p_menu_id 传 '00000000-0000-0000-0000-000000000000'（零 uuid 哨兵，
--       current_user_id 无登录兜底同款约定）→ NULL；其余 NULL 参数 = 不修改
--   D5 api_code 单码制: 重复 code 拒绝（22023）；'' → NULL 允许留空
--       （既有 14 行 api_code IS NULL 现状兼容）；path+method 重复拒绝（22023，
--       唯一索引 23505 预检成友好错误）
-- 源文件: 无（菜单 CRUD 同惯例，管理 RPC 仅迁移层定义；api_v1/public/rpc/
--       无同名文件，apply-src 重放无覆盖冲突）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 权限点 seed（042 风格：带 menu_id/api_group；ApiList 菜单 = API管理 分组）
-- ---------------------------------------------------------------------------
INSERT INTO iam_api (path, method, name, description, api_code, menu_id, api_group, created_by)
SELECT '/rpc/sys:api:create', 'POST', 'API-新增',
       'API 权限点新增（rpc_create_api）', 'sys:api:create',
       m.id, 'API管理', NULL
FROM iam_menu m WHERE m.menu_name = 'ApiList'
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_api (path, method, name, description, api_code, menu_id, api_group, created_by)
SELECT '/rpc/sys:api:update', 'POST', 'API-修改',
       'API 权限点修改（rpc_update_api）', 'sys:api:update',
       m.id, 'API管理', NULL
FROM iam_menu m WHERE m.menu_name = 'ApiList'
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_api (path, method, name, description, api_code, menu_id, api_group, created_by)
SELECT '/rpc/sys:api:delete', 'POST', 'API-删除',
       'API 权限点删除（rpc_delete_api；有角色绑定拒绝）', 'sys:api:delete',
       m.id, 'API管理', NULL
FROM iam_menu m WHERE m.menu_name = 'ApiList'
ON CONFLICT (path, method) DO NOTHING;

INSERT INTO iam_role_api (role_code, api_id, created_by)
SELECT 'role_super_admin', a.id, NULL
FROM iam_api a WHERE a.api_code IN ('sys:api:create','sys:api:update','sys:api:delete')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §2 rpc_create_api — 新增 API 权限点（sys:api:create）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_api(
    p_path text, p_method text, p_name text,
    p_api_code text DEFAULT NULL, p_description text DEFAULT NULL,
    p_is_active boolean DEFAULT true,
    p_menu_id uuid DEFAULT NULL, p_api_group text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:api:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_path IS NULL OR trim(p_path) = '' THEN
        RAISE EXCEPTION 'path required' USING ERRCODE = '22023';
    END IF;
    IF p_method IS NULL OR trim(p_method) = '' THEN
        RAISE EXCEPTION 'method required' USING ERRCODE = '22023';
    END IF;
    IF p_name IS NULL OR trim(p_name) = '' THEN
        RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM iam_api WHERE path = trim(p_path) AND method = upper(p_method)) THEN
        RAISE EXCEPTION 'path+method exists' USING ERRCODE = '22023';
    END IF;
    IF p_api_code IS NOT NULL AND trim(p_api_code) <> ''
       AND EXISTS (SELECT 1 FROM iam_api WHERE api_code = trim(p_api_code)) THEN
        RAISE EXCEPTION 'api_code exists' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_api (path, method, name, description, api_code, is_active,
                         menu_id, api_group, created_by)
    VALUES (trim(p_path), upper(p_method), trim(p_name), NULLIF(trim(p_description), ''),
            NULLIF(trim(p_api_code), ''), p_is_active, p_menu_id,
            -- 分组默认随归属菜单名（表单默认值服务端落地）
            COALESCE(NULLIF(trim(p_api_group), ''),
                     (SELECT menu_name FROM iam_menu WHERE id = p_menu_id)),
            current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('api', 'create', 'iam_api', v_id::text,
                        'success', jsonb_build_object('code', p_api_code, 'path', p_path,
                                                      'method', p_method, 'name', p_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_api(text, text, text, text, text, boolean, uuid, text) IS 'API 权限点新增（sys:api:create；api_code 重复/path+method 重复拒绝 22023；p_api_group 为空时默认取归属菜单名；method 自动大写）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_api(text, text, text, text, text, boolean, uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 rpc_update_api — 修改 API 权限点（sys:api:update；清空语义见 D4）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_api(
    p_id uuid, p_path text DEFAULT NULL, p_method text DEFAULT NULL,
    p_name text DEFAULT NULL, p_api_code text DEFAULT NULL,
    p_description text DEFAULT NULL, p_is_active boolean DEFAULT NULL,
    p_menu_id uuid DEFAULT NULL, p_api_group text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_new_code text;
BEGIN
    IF NOT has_permission('public:api:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam_api WHERE id = p_id) THEN
        RAISE EXCEPTION 'api not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_path IS NOT NULL AND trim(p_path) <> ''
       AND EXISTS (SELECT 1 FROM iam_api
                   WHERE path = trim(p_path) AND method = upper(COALESCE(p_method, method))
                     AND id <> p_id) THEN
        RAISE EXCEPTION 'path+method exists' USING ERRCODE = '22023';
    END IF;
    -- api_code 清空语义: '' → NULL；重复检查排除自身
    v_new_code := NULLIF(trim(p_api_code), '');
    IF p_api_code IS NOT NULL AND v_new_code IS NOT NULL
       AND EXISTS (SELECT 1 FROM iam_api WHERE api_code = v_new_code AND id <> p_id) THEN
        RAISE EXCEPTION 'api_code exists' USING ERRCODE = '22023';
    END IF;
    UPDATE iam_api SET
        path        = COALESCE(NULLIF(trim(p_path), ''), path),
        method      = COALESCE(upper(p_method), method),
        name        = COALESCE(NULLIF(trim(p_name), ''), name),
        api_code    = CASE WHEN p_api_code IS NOT NULL THEN v_new_code ELSE api_code END,
        description = CASE WHEN p_description IS NOT NULL AND trim(p_description) = ''
                           THEN NULL ELSE COALESCE(p_description, description) END,
        is_active   = COALESCE(p_is_active, is_active),
        menu_id     = CASE WHEN p_menu_id = '00000000-0000-0000-0000-000000000000'
                           THEN NULL ELSE COALESCE(p_menu_id, menu_id) END,
        api_group   = CASE WHEN p_api_group IS NOT NULL AND trim(p_api_group) = ''
                           THEN NULL ELSE COALESCE(p_api_group, api_group) END,
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('api', 'update', 'iam_api', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_update_api(uuid, text, text, text, text, text, boolean, uuid, text) IS 'API 权限点修改（sys:api:update；NULL=不改；文本传 '' '' 清空，menu_id 传零 uuid 清空归属；api_code/path+method 重复拒绝 22023）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_api(uuid, text, text, text, text, text, boolean, uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 rpc_delete_api — 删除 API 权限点（sys:api:delete；有角色绑定拒绝）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_delete_api(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('public:api:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam_api WHERE id = p_id) THEN
        RAISE EXCEPTION 'api not found' USING ERRCODE = 'P0002';
    END IF;
    IF EXISTS (SELECT 1 FROM iam_role_api WHERE api_id = p_id) THEN
        RAISE EXCEPTION 'has role bindings, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM iam_api WHERE id = p_id;
    PERFORM log_operate('api', 'delete', 'iam_api', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_delete_api(uuid) IS 'API 权限点删除（sys:api:delete；iam_role_api 有绑定拒绝 23503——先解绑再删，避免 CASCADE 静默清授权）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_delete_api(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 验证（结构 + 真实冒烟含审计链路，042 同款伪 claims）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_fns       int;
    v_codes     int;
    v_binds     int;
    v_ret       json;
    v_id        uuid;
    v_row       record;
    v_api_group text;
    v_created_by text;
    v_dup_ok    boolean := false;
    v_code_ok   boolean := false;
    v_del_ok    boolean := false;
    v_deny_ok   boolean := false;
BEGIN
    -- 结构: 3 函数 + 3 权限点 + 3 超管绑定
    SELECT count(*) INTO v_fns FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public'
      AND p.proname IN ('rpc_create_api','rpc_update_api','rpc_delete_api');
    SELECT count(*) INTO v_codes FROM iam_api
    WHERE api_code IN ('sys:api:create','sys:api:update','sys:api:delete');
    SELECT count(*) INTO v_binds FROM iam_role_api
    WHERE role_code = 'role_super_admin'
      AND api_id IN (SELECT id FROM iam_api WHERE api_code IN ('sys:api:create','sys:api:update','sys:api:delete'));

    -- 冒烟: 超管 claims → create（分组默认取归属菜单名——menu_name 如 ApiList；
    -- current_user_id() 读 Logto sub claim）
    PERFORM set_config('request.jwt.claims',
        '{"roles":["role_super_admin"],"sub":"__smoke_043__"}', true);
    v_ret := api_v1_public.rpc_create_api(
        p_path => '/rpc/__smoke_043__', p_method => 'get', p_name => '冒烟测试API',
        p_api_code => 'sys:smoke:043', p_menu_id => (SELECT id FROM iam_menu WHERE menu_name = 'ApiList'));
    v_id := (v_ret->>'id')::uuid;
    SELECT api_group, created_by INTO v_api_group, v_created_by
    FROM iam_api WHERE id = v_id;
    IF v_api_group IS DISTINCT FROM 'ApiList' THEN
        RAISE EXCEPTION '043 验证失败: api_group 默认未取归属菜单名（%）', v_api_group;
    END IF;
    IF v_created_by IS DISTINCT FROM '__smoke_043__' THEN
        RAISE EXCEPTION '043 验证失败: created_by 未写入（%）', v_created_by;
    END IF;

    -- 更新: 改 code + 清空分组/归属/描述（'' 与零 uuid 哨兵）
    PERFORM api_v1_public.rpc_update_api(
        p_id => v_id, p_api_code => 'sys:smoke:043b', p_is_active => false,
        p_api_group => '', p_menu_id => '00000000-0000-0000-0000-000000000000',
        p_description => '');
    SELECT api_code, api_group, menu_id, description, is_active
      INTO v_row FROM iam_api WHERE id = v_id;
    IF v_row.api_code <> 'sys:smoke:043b' OR v_row.api_group IS NOT NULL
       OR v_row.menu_id IS NOT NULL OR v_row.description IS NOT NULL
       OR v_row.is_active <> false THEN
        RAISE EXCEPTION '043 验证失败: update 清空/更新未生效（%）', row_to_json(v_row)::text;
    END IF;

    -- 拒绝路径: 重复 path+method / 重复 api_code（22023）
    BEGIN
        PERFORM api_v1_public.rpc_create_api('/rpc/__smoke_043__', 'GET', '重复');
        RAISE EXCEPTION '043 验证失败: 重复 path+method 未拒绝';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_dup_ok := true;
    END;
    BEGIN
        PERFORM api_v1_public.rpc_create_api('/rpc/__smoke_043b__', 'GET', '重复码',
                                             p_api_code => 'sys:smoke:043b');
        RAISE EXCEPTION '043 验证失败: 重复 api_code 未拒绝';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_code_ok := true;
    END;

    -- 拒绝路径: 有角色绑定不可删（23503）；解绑后可删
    INSERT INTO iam_role_api (role_code, api_id) VALUES ('__smoke_role__', v_id);
    BEGIN
        PERFORM api_v1_public.rpc_delete_api(v_id);
        RAISE EXCEPTION '043 验证失败: 有绑定未拒绝删除';
    EXCEPTION WHEN foreign_key_violation THEN
        v_del_ok := true;
    END;
    DELETE FROM iam_role_api WHERE role_code = '__smoke_role__' AND api_id = v_id;
    PERFORM api_v1_public.rpc_delete_api(v_id);
    IF EXISTS (SELECT 1 FROM iam_api WHERE id = v_id) THEN
        RAISE EXCEPTION '043 验证失败: 删除后仍存在';
    END IF;

    -- 匿名上下文拒绝（无 claims → 无权限）
    PERFORM set_config('request.jwt.claims', '{}', true);
    BEGIN
        PERFORM api_v1_public.rpc_create_api('/rpc/__smoke_043c__', 'GET', '匿名');
        RAISE EXCEPTION '043 验证失败: 匿名未拒绝';
    EXCEPTION WHEN insufficient_privilege THEN
        v_deny_ok := true;
    END;

    RAISE NOTICE '043: 函数=%（期望3） 权限点=%（期望3） 绑定=%（期望3） 冒烟: 分组派生=% 清空=% 重复path=% 重复code=% 绑定拒删=% 匿名拒绝=%',
        v_fns, v_codes, v_binds, v_api_group = 'ApiList', v_row.api_group IS NULL,
        v_dup_ok, v_code_ok, v_del_ok, v_deny_ok;

    IF v_fns <> 3 OR v_codes <> 3 OR v_binds <> 3
       OR v_api_group IS DISTINCT FROM 'ApiList' OR v_row.api_group IS NOT NULL
       OR NOT v_dup_ok OR NOT v_code_ok OR NOT v_del_ok OR NOT v_deny_ok THEN
        RAISE EXCEPTION '043 验证失败';
    END IF;
    RAISE NOTICE '043: 全部验证通过';
END $$;
