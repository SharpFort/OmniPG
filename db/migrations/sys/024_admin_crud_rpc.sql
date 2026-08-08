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
CREATE OR REPLACE FUNCTION log_operate(
    p_module      text,
    p_action      text,
    p_target_type text DEFAULT NULL,
    p_target_id   text DEFAULT NULL,
    p_result      text DEFAULT 'success',
    p_detail      jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO audit_log
        (log_type, module, action, target_type, target_id, result,
         new_data, user_id, tenant_id, created_at)
    VALUES
        ('operate', p_module, p_action, p_target_type, p_target_id, p_result,
         p_detail, current_user_id(), current_tenant_id(), now());
END;
$$;
COMMENT ON FUNCTION log_operate(text, text, text, text, text, jsonb) IS '操作审计统一写入（log_type=operate）；ip/ua 由网关 access log 覆盖（PostgREST 不注入）';

-- ---------------------------------------------------------------------------
-- §2 部门 CRUD（department，租户隔离）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_create_department(
    p_dept_name text, p_parent_id uuid DEFAULT NULL, p_sort_order int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('sys:dept:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dept_name IS NULL OR trim(p_dept_name) = '' THEN
        RAISE EXCEPTION 'dept_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO department (tenant_id, dept_name, parent_id, sort_order, created_by)
    VALUES (current_tenant_id(), p_dept_name, p_parent_id, p_sort_order, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dept', 'create', 'department', v_id::text,
                        'success', jsonb_build_object('name', p_dept_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_create_department(text, uuid, int) IS '部门新增（sys:dept:create）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_create_department(text, uuid, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_department(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_dept_name text DEFAULT NULL,
    p_sort_order int DEFAULT NULL, p_is_active boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:dept:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM department
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'dept not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE department SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        dept_name   = COALESCE(p_dept_name, dept_name),
        sort_order  = COALESCE(p_sort_order, sort_order),
        is_active   = COALESCE(p_is_active, is_active),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('dept', 'update', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_department(uuid, uuid, text, int, boolean) IS '部门修改（sys:dept:update）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_department(uuid, uuid, text, int, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_delete_department(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:dept:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM department
               WHERE parent_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_profile
               WHERE dept_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM department WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('dept', 'delete', 'department', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_delete_department(uuid) IS '部门删除（sys:dept:delete；有子部门/关联用户拒绝）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_delete_department(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 岗位 CRUD + 分配 + 树（position / user_position，租户隔离）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_get_position_tree()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('sys:position:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    WITH RECURSIVE tree AS (
        SELECT id, parent_id, pos_name, pos_code, sort_no, status,
               1 AS depth, pos_name::text AS path_name
        FROM position
        WHERE parent_id IS NULL AND tenant_id = current_tenant_id()
        UNION ALL
        SELECT p.id, p.parent_id, p.pos_name, p.pos_code, p.sort_no, p.status,
               t.depth + 1, t.path_name::text || ' / ' || p.pos_name::text
        FROM position p JOIN tree t ON p.parent_id = t.id
        WHERE p.tenant_id = current_tenant_id()
    )
    SELECT json_agg(row_to_json(x) ORDER BY x.path_name)
      INTO v_result
    FROM (SELECT id, parent_id, pos_name, pos_code, sort_no, status, depth, path_name
          FROM tree) x;
    RETURN COALESCE(v_result, '[]'::json);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_get_position_tree() IS '岗位树（递归 CTE + 层级路径；sys:position:list；替代 v_position_tree 视图方案）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_get_position_tree() TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_create_position(
    p_pos_name text, p_parent_id uuid DEFAULT NULL, p_pos_code text DEFAULT NULL,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('sys:position:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_pos_name IS NULL OR trim(p_pos_name) = '' THEN
        RAISE EXCEPTION 'pos_name required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO position (tenant_id, pos_name, pos_code, parent_id, sort_no, created_by)
    VALUES (current_tenant_id(), p_pos_name, p_pos_code, p_parent_id, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('position', 'create', 'position', v_id::text,
                        'success', jsonb_build_object('name', p_pos_name));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_create_position(text, uuid, text, int) IS '岗位新增（sys:position:create）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_create_position(text, uuid, text, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_position(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_pos_name text DEFAULT NULL,
    p_pos_code text DEFAULT NULL, p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:position:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM position
                   WHERE id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'position not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE position SET
        parent_id  = COALESCE(p_parent_id, parent_id),
        pos_name   = COALESCE(p_pos_name, pos_name),
        pos_code   = COALESCE(p_pos_code, pos_code),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'update', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_position(uuid, uuid, text, text, int, boolean) IS '岗位修改（sys:position:update）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_position(uuid, uuid, text, text, int, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_delete_position(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:position:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM position
               WHERE parent_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM user_position
               WHERE position_id = p_id AND tenant_id = current_tenant_id()) THEN
        RAISE EXCEPTION 'has users, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM position WHERE id = p_id AND tenant_id = current_tenant_id();
    PERFORM log_operate('position', 'delete', 'position', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_delete_position(uuid) IS '岗位删除（sys:position:delete；有子岗位/关联用户拒绝）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_delete_position(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_assign_user_positions(
    p_user_id text, p_position_ids uuid[], p_primary_position_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text := current_tenant_id();
BEGIN
    IF NOT has_permission('sys:position:assign') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 目标用户必须是本租户成员
    IF NOT EXISTS (SELECT 1 FROM user_tenants
                   WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
    END IF;
    -- 全量覆盖分配
    DELETE FROM user_position
    WHERE user_id = p_user_id AND tenant_id = v_tenant;
    IF p_position_ids IS NOT NULL THEN
        INSERT INTO user_position (user_id, position_id, tenant_id, is_primary, created_by)
        SELECT p_user_id, g, v_tenant,
               (g = p_primary_position_id), current_user_id()
        FROM unnest(p_position_ids) AS g;
    END IF;
    PERFORM log_operate('position', 'assign', 'user_position', p_user_id,
                        'success', jsonb_build_object('positions', p_position_ids));
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_assign_user_positions(text, uuid[], uuid) IS '用户岗位分配（全量覆盖；sys:position:assign；目标用户须为本租户成员）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_assign_user_positions(text, uuid[], uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 字典 CRUD（dict_type / dict_data；全局字典仅超管可写）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_create_dict_type(
    p_dict_name text, p_dict_label text, p_tenant_scoped boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('sys:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_dict_name IS NULL OR trim(p_dict_name) = '' THEN
        RAISE EXCEPTION 'dict_name required' USING ERRCODE = '22023';
    END IF;
    v_tenant := CASE WHEN p_tenant_scoped THEN current_tenant_id() ELSE NULL END;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_type (tenant_id, dict_name, dict_label, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_dict_label, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_type', v_id::text,
                        'success', jsonb_build_object('name', p_dict_name, 'tenant_scoped', p_tenant_scoped));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_create_dict_type(text, text, boolean, int) IS '字典类型新增（sys:dict:create；全局字典仅超管）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_create_dict_type(text, text, boolean, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_dict_type(
    p_id uuid, p_dict_label text DEFAULT NULL, p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('sys:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_type SET
        dict_label = COALESCE(p_dict_label, dict_label),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_type', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_dict_type(uuid, text, int, boolean) IS '字典类型修改（sys:dict:update；租户/全局作用域校验）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_dict_type(uuid, text, int, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_delete_dict_type(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text; v_name text;
BEGIN
    IF NOT has_permission('sys:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id, dict_name INTO v_tenant, v_name FROM dict_type WHERE id = p_id;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'dict not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
    END IF;
    IF v_tenant IS NOT NULL AND v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 级联删除同作用域的数据项（dict_data 无 FK，手动清理）
    DELETE FROM dict_data WHERE dict_name = v_name
        AND tenant_id IS NOT DISTINCT FROM v_tenant;
    DELETE FROM dict_type WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_type', p_id::text,
                        'success', jsonb_build_object('name', v_name));
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_delete_dict_type(uuid) IS '字典类型删除（sys:dict:delete；级联清理同作用域数据项）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_delete_dict_type(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_create_dict_data(
    p_dict_name text, p_item_label text, p_item_value text,
    p_item_type text DEFAULT 'default', p_is_default boolean DEFAULT false,
    p_sort_no int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_tenant text;
BEGIN
    IF NOT has_permission('sys:dict:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 字典类型必须存在，且作用域匹配当前租户（或全局超管）
    SELECT tenant_id INTO v_tenant FROM dict_type WHERE dict_name = p_dict_name;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_type WHERE dict_name = p_dict_name) THEN
            RAISE EXCEPTION 'dict type not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    INSERT INTO dict_data (tenant_id, dict_name, item_label, item_value,
                           item_type, is_default, sort_no, created_by)
    VALUES (v_tenant, p_dict_name, p_item_label, p_item_value,
            p_item_type, p_is_default, p_sort_no, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('dict', 'create', 'dict_data', v_id::text,
                        'success', jsonb_build_object('dict', p_dict_name, 'value', p_item_value));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_create_dict_data(text, text, text, text, boolean, int) IS '字典数据新增（sys:dict:create；类型存在性与作用域校验）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_create_dict_data(text, text, text, text, boolean, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_dict_data(
    p_id uuid, p_item_label text DEFAULT NULL, p_item_value text DEFAULT NULL,
    p_item_type text DEFAULT NULL, p_is_default boolean DEFAULT NULL,
    p_sort_no int DEFAULT NULL, p_status boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('sys:dict:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_data WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    UPDATE dict_data SET
        item_label = COALESCE(p_item_label, item_label),
        item_value = COALESCE(p_item_value, item_value),
        item_type  = COALESCE(p_item_type, item_type),
        is_default = COALESCE(p_is_default, is_default),
        sort_no    = COALESCE(p_sort_no, sort_no),
        status     = COALESCE(p_status, status),
        updated_at = now(),
        updated_by = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('dict', 'update', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_dict_data(uuid, text, text, text, boolean, int, boolean) IS '字典数据修改（sys:dict:update）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_dict_data(uuid, text, text, text, boolean, int, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_delete_dict_data(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tenant text;
BEGIN
    IF NOT has_permission('sys:dict:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT tenant_id INTO v_tenant FROM dict_data WHERE id = p_id;
    IF v_tenant IS NULL THEN
        IF NOT EXISTS (SELECT 1 FROM dict_data WHERE id = p_id) THEN
            RAISE EXCEPTION 'dict item not found' USING ERRCODE = 'P0002';
        END IF;
        IF NOT is_super_admin() THEN
            RAISE EXCEPTION 'global dict requires super admin' USING ERRCODE = '42501';
        END IF;
    ELSIF v_tenant <> current_tenant_id() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    DELETE FROM dict_data WHERE id = p_id;
    PERFORM log_operate('dict', 'delete', 'dict_data', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_delete_dict_data(uuid) IS '字典数据删除（sys:dict:delete）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_delete_dict_data(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 菜单/角色绑定管理（iam_menu / iam_role_api / iam_role_menu，平台级）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_perms text DEFAULT NULL, p_path text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0,
    p_is_visible boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('sys:menu:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_name IS NULL OR trim(p_menu_name) = '' THEN
        RAISE EXCEPTION 'menu_name required' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type NOT IN ('directory','menu','button') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, perms, path, component,
                          icon, order_num, is_visible, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type, p_perms, p_path, p_component,
            p_icon, p_order_num, p_is_visible, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean) IS '菜单新增（sys:menu:create；menu_type: directory/menu/button；035 +p_is_visible 对齐 RuoYi 新增表单）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_perms text DEFAULT NULL, p_path text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:menu:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam_menu WHERE id = p_id) THEN
        RAISE EXCEPTION 'menu not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type, menu_type),
        perms       = COALESCE(p_perms, perms),
        path        = COALESCE(p_path, path),
        component   = COALESCE(p_component, component),
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) IS '菜单修改（sys:menu:update）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_delete_menu(p_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:menu:delete') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM iam_menu WHERE parent_id = p_id) THEN
        RAISE EXCEPTION 'has children, cannot delete' USING ERRCODE = '23503';
    END IF;
    DELETE FROM iam_role_menu WHERE menu_id = p_id;
    DELETE FROM iam_menu WHERE id = p_id;
    PERFORM log_operate('menu', 'delete', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_delete_menu(uuid) IS '菜单删除（sys:menu:delete；有子菜单拒绝；级联清绑定）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_delete_menu(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_set_role_apis(p_role_code text, p_api_codes text[])
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:role-api:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_role_code IS NULL OR NOT EXISTS (SELECT 1 FROM role WHERE name = p_role_code) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    -- 全量覆盖：角色→API 绑定
    DELETE FROM iam_role_api WHERE role_code = p_role_code;
    IF p_api_codes IS NOT NULL THEN
        INSERT INTO iam_role_api (role_code, api_id, created_by)
        SELECT p_role_code, a.id, current_user_id()
        FROM iam_api a
        WHERE a.api_code = ANY (p_api_codes) AND a.is_active
        ON CONFLICT (role_code, api_id) DO NOTHING;
    END IF;
    PERFORM log_operate('role', 'bind-apis', 'role', p_role_code,
                        'success', jsonb_build_object('api_codes', p_api_codes));
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_set_role_apis(text, text[]) IS '角色→API 权限绑定（全量覆盖；sys:role-api:bind；角色须为 Logto 镜像内角色）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_set_role_apis(text, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_set_role_menus(p_role_code text, p_menu_ids uuid[])
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT has_permission('sys:role-menu:bind') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_role_code IS NULL OR NOT EXISTS (SELECT 1 FROM role WHERE name = p_role_code) THEN
        RAISE EXCEPTION 'role not found' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM iam_role_menu WHERE role_code = p_role_code;
    IF p_menu_ids IS NOT NULL THEN
        INSERT INTO iam_role_menu (role_code, menu_id, created_by)
        SELECT p_role_code, g, current_user_id()
        FROM unnest(p_menu_ids) AS g
        ON CONFLICT (role_code, menu_id) DO NOTHING;
    END IF;
    PERFORM log_operate('role', 'bind-menus', 'role', p_role_code,
                        'success', jsonb_build_object('menu_ids', p_menu_ids));
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_set_role_menus(text, uuid[]) IS '角色→菜单绑定（全量覆盖；sys:role-menu:bind）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_set_role_menus(text, uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 用户资料（user_profile，动态列白名单模式）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_get_user_profile(p_user_id text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_row json; v_tenant text := current_tenant_id();
BEGIN
    -- 本人 / 超管 / 本租户成员（管理端查看）
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'user_id required' USING ERRCODE = '22023';
    END IF;
    IF p_user_id <> current_user_id() AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT COALESCE(row_to_json(p), '{}'::json) INTO v_row
    FROM user_profile p WHERE p.user_id = p_user_id;
    RETURN COALESCE(v_row, '{}'::json);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_get_user_profile(text) IS '用户资料查询（本人/超管/本租户成员）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_get_user_profile(text) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_update_user_profile(p_user_id text, p_updates jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_tenant text := current_tenant_id();
    v_self   boolean;
    v_sql    text;
    v_col    text;
BEGIN
    IF p_user_id IS NULL OR p_updates IS NULL THEN
        RAISE EXCEPTION 'user_id and updates required' USING ERRCODE = '22023';
    END IF;
    -- 权限：本人改自己（免权限点）或超管/本租户管理成员（需权限点）
    v_self := (p_user_id = current_user_id());
    IF NOT v_self THEN
        IF NOT has_permission('sys:profile:update') THEN
            RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
        END IF;
        IF NOT is_super_admin()
           AND NOT EXISTS (SELECT 1 FROM user_tenants
                           WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
            RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- 动态列白名单：仅允许 user_profile 的业务列（排除主键/租户/审计列）
    FOR v_col IN
        SELECT c.column_name
        FROM information_schema.columns c
        WHERE c.table_schema = 'public' AND c.table_name = 'user_profile'
          AND c.column_name NOT IN
              ('user_id','tenant_id','dept_id','created_at','updated_at',
               'deleted_at','created_by','updated_by','deleted_by')
          AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
    LOOP
        v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L, updated_at = now(), updated_by = %L WHERE user_id = %L',
                        v_col, v_col, current_user_id(), p_user_id);
        EXECUTE v_sql USING p_updates;
    END LOOP;
    -- 档案行不存在则建档（JIT 语义）
    IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM user_profile WHERE user_id = p_user_id) THEN
        INSERT INTO user_profile (user_id, tenant_id, created_by)
        VALUES (p_user_id, v_tenant, current_user_id());
        -- 再执行一次白名单更新（简化：仅重放首轮）
        FOR v_col IN
            SELECT c.column_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'public' AND c.table_name = 'user_profile'
              AND c.column_name NOT IN
                  ('user_id','tenant_id','dept_id','created_at','updated_at',
                   'deleted_at','created_by','updated_by','deleted_by')
              AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
        LOOP
            v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L WHERE user_id = %L',
                            v_col, v_col, p_user_id);
            EXECUTE v_sql USING p_updates;
        END LOOP;
    END IF;
    PERFORM log_operate('profile', 'update', 'user_profile', p_user_id,
                        'success', p_updates);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_sys.rpc_update_user_profile(text, jsonb) IS '用户资料更新（本人免权限点；管理他人需 sys:profile:update；动态列白名单）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_update_user_profile(text, jsonb) TO authenticated;

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

ALTER TABLE public.user_role ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_role_read_policy ON public.user_role;
CREATE POLICY user_role_read_policy ON public.user_role
FOR SELECT
USING (is_super_admin() OR user_id = current_user_id());

-- ---------------------------------------------------------------------------
-- §7 视图：v_dict_list / v_user_roles / v_role_users
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_dict_list CASCADE;
CREATE VIEW api_v1_sys.v_dict_list AS
SELECT t.id, t.tenant_id, t.dict_name, t.dict_label, t.status, t.sort_no, t.remark,
       COALESCE((
           SELECT json_agg(json_build_object(
               'id', d.id, 'label', d.item_label, 'value', d.item_value,
               'type', d.item_type, 'is_default', d.is_default,
               'sort_no', d.sort_no, 'status', d.status) ORDER BY d.sort_no)
           FROM dict_data d
           WHERE d.dict_name = t.dict_name
             AND d.tenant_id IS NOT DISTINCT FROM t.tenant_id
             AND d.status),
           '[]'::json) AS items
FROM dict_type t;
COMMENT ON VIEW api_v1_sys.v_dict_list IS '字典组合视图（类型 + 数据项聚合）';

DROP VIEW IF EXISTS api_v1_sys.v_user_roles CASCADE;
CREATE VIEW api_v1_sys.v_user_roles AS
SELECT u.id AS user_id, u.username, u.primary_email AS email,
       ur.role_code, ur.created_at AS assigned_at
FROM users u
LEFT JOIN user_role ur ON ur.user_id = u.id;
COMMENT ON VIEW api_v1_sys.v_user_roles IS '用户→角色镜像视图（user_role 分配镜像，管理端详情页）';

DROP VIEW IF EXISTS api_v1_sys.v_role_users CASCADE;
CREATE VIEW api_v1_sys.v_role_users AS
SELECT r.name AS role_code, r.id AS role_id, r.type AS role_type,
       ur.user_id, u.username
FROM role r
LEFT JOIN user_role ur ON ur.role_code = r.role_code
LEFT JOIN users u ON u.id = ur.user_id;
COMMENT ON VIEW api_v1_sys.v_role_users IS '角色→用户镜像视图（管理端角色详情-成员标签页；035: JOIN 键改 r.role_code 清晰化——生成列恒等于 name，原写法碰巧正确）';

-- ---------------------------------------------------------------------------
-- §8 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fn int; v_perms int; v_views int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_sys'::regnamespace
        AND proname IN ('rpc_create_department','rpc_update_department','rpc_delete_department',
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
