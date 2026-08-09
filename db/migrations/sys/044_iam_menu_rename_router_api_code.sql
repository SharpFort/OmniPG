-- =============================================================================
-- 044_iam_menu_rename_router_api_code.sql — iam_menu 字段改名 + iam_api 排序 + 按钮/接口数据整理
-- =============================================================================
-- 背景: 2026-08-09 用户拍板（菜单/API 资源树一体化方案，字段分析结论落地）
--   D1 iam_menu.perms → api_code（与 iam_api.api_code 字段统一——单码制"表结构自解释"；
--      040 双通道 has_permission 语义不变）
--   D2 iam_menu.path  → router（消除与 iam_api.path 同名异义；对齐参考项目 sharpfort
--      Menu.Router/RouterName 心智）
--   D3 iam_api.order_num 新增（资源树接口叶子排序，与 iam_menu.order_num 对齐）
--   D4 数据整理: 3 按钮（UserAdd/UserEdit/UserDelete）parent_id ApiList→UserList（011 历史
--      布局归位）；3 个 sys:user:* 接口 menu_id UserList→对应按钮（首个"按钮>接口"1:1 实例）
-- 影响面（函数体为文本存储，RENAME COLUMN 不自动更新，必须显式重建）:
--   视图: api_v1_public.iam_menu（列名变 router/api_code）、v_role_menu_detail
--         （源列改、输出别名 permission_code/menu_path 不变）、casbin_rule（m.path→m.router）
--   函数: has_permission（m.perms→m.api_code）、rpc_create_menu/rpc_update_menu
--         （参数 p_perms→p_api_code、p_path→p_router——PostgREST 按参数名传参，前端同步改）、
--         get_user_menu / get_menu_tree_admin / get_role_permissions
--         （源列改，输出字段名 path/perms 保持——前端路由构建/角色授权契约不变）
-- 权限: DROP+CREATE 视图丢失 GRANT → 重建后补授 authenticated/super_admin
--       （函数用 CREATE OR REPLACE，GRANT 保留）
-- 注意: RENAME COLUMN 自动更新同表 CHECK 约束定义（约束名保留——038/040 迁移幂等依赖旧名）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_menu 列改名（幂等：先查列存在性）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='perms') THEN
        ALTER TABLE public.iam_menu RENAME COLUMN perms TO api_code;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='path') THEN
        ALTER TABLE public.iam_menu RENAME COLUMN path TO router;
    END IF;
END $$;

COMMENT ON COLUMN public.iam_menu.api_code IS '权限码（单码制：与 iam_api.api_code 同码；button 必填，has_permission 双通道判定键；原 perms）';
COMMENT ON COLUMN public.iam_menu.router IS '路由地址（前端 vue-router path；link 类型为 http(s):// 外链 URL；原 path）';

-- ---------------------------------------------------------------------------
-- §2 iam_api 加排序字段（资源树接口叶子排序）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_api ADD COLUMN IF NOT EXISTS order_num integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.iam_api.order_num IS '排序（资源树接口叶子在父节点下的顺序，与 iam_menu.order_num 对齐）';

-- ---------------------------------------------------------------------------
-- §3 数据整理（D4；幂等：条件限定旧挂载点，重放不重复移动）
-- ---------------------------------------------------------------------------
-- 3.1 按钮归位: ApiList → UserList
UPDATE public.iam_menu SET parent_id = u.id
FROM public.iam_menu u
WHERE u.menu_name = 'UserList' AND u.menu_type = 'directory'
  AND iam_menu.menu_name IN ('UserAdd','UserEdit','UserDelete')
  AND iam_menu.menu_type = 'button'
  AND iam_menu.parent_id = (SELECT id FROM public.iam_menu
                            WHERE menu_name = 'ApiList' AND menu_type = 'menu');

-- 3.2 接口挂按钮（1:1 关联首个实例：api_code 单码制匹配按钮）
UPDATE public.iam_api a SET menu_id = b.id
FROM public.iam_menu b
WHERE b.menu_type = 'button'
  AND b.menu_name = CASE a.api_code
        WHEN 'sys:user:add'    THEN 'UserAdd'
        WHEN 'sys:user:edit'   THEN 'UserEdit'
        WHEN 'sys:user:delete' THEN 'UserDelete' END
  AND a.api_code IN ('sys:user:add','sys:user:edit','sys:user:delete')
  AND a.menu_id = (SELECT id FROM public.iam_menu
                   WHERE menu_name = 'UserList' AND menu_type = 'directory');

-- ---------------------------------------------------------------------------
-- §4 视图重建（列名/源列跟随表；输出别名契约保持）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.v_role_menu_detail CASCADE;
DROP VIEW IF EXISTS public.casbin_rule CASCADE;
DROP VIEW IF EXISTS api_v1_public.iam_menu CASCADE;

CREATE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, query, is_link, is_iframe, redirect, keep_alive,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（044: perms→api_code / path→router 列改名）';

CREATE VIEW api_v1_public.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.menu_name AS menu_name,
    m.menu_type AS menu_type,
    m.api_code AS permission_code,
    m.router AS menu_path,
    m.icon AS menu_icon,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_public.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu；044 源列改名，输出别名不变）';

CREATE VIEW public.casbin_rule AS
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    ra.role_code::varchar AS v0,
    a.path::varchar AS v1,
    a.method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_api ra
JOIN iam_api a ON ra.api_id = a.id
WHERE a.is_active = true
UNION ALL
SELECT
    NULL::integer,
    'p'::varchar,
    rm.role_code::varchar AS v0,
    m.router::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar,
    NULL::varchar,
    NULL::varchar
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active = true;
COMMENT ON VIEW public.casbin_rule IS 'Casbin 策略运行视图 — Logto 版（044: 菜单路径列 path→router）；v0=role_code, v1=资源, v2=action';

-- 视图权限补授（DROP+CREATE 丢失 GRANT）
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT SELECT ON api_v1_public.v_role_menu_detail TO authenticated;
GRANT ALL ON api_v1_public.iam_menu TO super_admin;
GRANT ALL ON api_v1_public.v_role_menu_detail TO super_admin;

-- ---------------------------------------------------------------------------
-- §5 函数重建（RENAME COLUMN 不更新函数体文本；CREATE OR REPLACE 保留 GRANT）
-- ---------------------------------------------------------------------------
-- 5.1 has_permission（040 双通道版：m.perms → m.api_code）
CREATE OR REPLACE FUNCTION has_permission(p_code text) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles text[];
BEGIN
    IF p_code IS NULL OR p_code = '' THEN
        RETURN false;
    END IF;

    -- 超管短路（RLS 例外同款语义）
    IF is_super_admin() THEN
        RETURN true;
    END IF;

    -- 从 JWT claims 提取角色（零查询原则：角色在 claims，绑定查小表）
    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;

    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN false;
    END IF;

    -- 双通道：API 权限点（api_code）∪ 菜单按钮权限码（menu.api_code；044 列改名）
    RETURN EXISTS (
        SELECT 1
        FROM iam_role_api ra
        JOIN iam_api a ON a.id = ra.api_id
        WHERE ra.role_code = ANY(v_roles)
          AND a.api_code = p_code
          AND a.is_active
        UNION ALL
        SELECT 1
        FROM iam_role_menu rm
        JOIN iam_menu m ON m.id = rm.menu_id
        WHERE rm.role_code = ANY(v_roles)
          AND m.api_code = p_code
          AND m.is_active
    );
END;
$$;
COMMENT ON FUNCTION has_permission(text) IS '权限点判定（044: 单码制双通道 role_api→api_code ∪ role_menu→menu.api_code；超管短路；按钮码与权限点同体系）';

-- 5.2 rpc_create_menu（参数 p_perms→p_api_code、p_path→p_router；040 单码制校验逻辑不变）
-- ⚠️ PG 不允许 CREATE OR REPLACE 修改参数名 → DROP+CREATE（GRANT 在下方重建）
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean);
CREATE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_api_code text DEFAULT NULL, p_router text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL)
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
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：button 必须 api_code（表级 CHECK 前置友好报错）
    IF p_menu_type = 'button' AND (p_api_code IS NULL OR trim(p_api_code) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 040 软校验：api_code 应对应 iam_api.api_code（新码可先建权限点，仅警告不阻断）
    IF p_api_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_api_code AND is_active) THEN
        RAISE NOTICE 'api_code [%] 未对应 iam_api.api_code——建议先建权限点再配按钮（单码制对齐）', p_api_code;
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, api_code, router, component,
                          icon, order_num, is_visible,
                          remark, route_name, query,
                          is_link, is_iframe, redirect, keep_alive, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type, p_api_code, p_router,
            p_component, p_icon, p_order_num, p_is_visible,
            p_remark, p_route_name, p_query,
            COALESCE(p_is_link, p_menu_type = 'link'), COALESCE(p_is_iframe, false),
            p_redirect, COALESCE(p_keep_alive, true), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单新增（sys:menu:create；044: 参数 p_perms→p_api_code/p_path→p_router——单码制）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

-- 5.3 rpc_update_menu（同上；DROP+CREATE 改参数名）
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean);
CREATE FUNCTION api_v1_public.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_api_code text DEFAULT NULL, p_router text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_api_code  text;
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
    IF p_menu_type IS NOT NULL AND p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：更新后类型为 button 必须 api_code（改类型或改码均按最终值校验）
    SELECT menu_type, api_code INTO v_menu_type, v_api_code FROM iam_menu WHERE id = p_id;
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (COALESCE(p_api_code, v_api_code) IS NULL OR trim(COALESCE(p_api_code, v_api_code)) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    IF p_api_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_api_code AND is_active) THEN
        RAISE NOTICE 'api_code [%] 未对应 iam_api.api_code——建议先建权限点再配按钮（单码制对齐）', p_api_code;
    END IF;
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type::iam_menu_type, menu_type),
        api_code    = COALESCE(p_api_code, api_code),
        router      = COALESCE(p_router, router),
        component   = COALESCE(p_component, component),
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        remark      = COALESCE(p_remark, remark),
        route_name  = COALESCE(p_route_name, route_name),
        query       = COALESCE(p_query, query),
        is_link     = COALESCE(p_is_link, p_menu_type = 'link', is_link),
        is_iframe   = COALESCE(p_is_iframe, is_iframe),
        redirect    = COALESCE(p_redirect, redirect),
        keep_alive  = COALESCE(p_keep_alive, keep_alive),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单修改（sys:menu:update；044: 参数 p_perms→p_api_code/p_path→p_router——单码制）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

-- 5.4 get_user_menu（源列改；输出字段名 path/perms 保持——前端 MenuProcessor/usePermission 契约不变）
CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_roles)) THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.keep_alive, m.redirect, m.query, m.route_name
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.keep_alive, m.redirect, m.query, m.route_name
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.is_active
    )
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_menu_tree
    FROM (
        SELECT
            c.id, c.parent_id, c.name, c.path,
            c.menu_type, c.perms, c.is_visible, c.component,
            c.is_link, c.is_iframe, c.keep_alive, c.redirect, c.query, c.route_name,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（044: 源列 path→router/perms→api_code，输出字段名保持）';

-- 5.5 get_menu_tree_admin（m.path → m.router，输出键 path 保持——前端 getMenuTreeAdmin 契约）
CREATE OR REPLACE FUNCTION api_v1_public.get_menu_tree_admin()
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE menu_tree AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.order_num AS sort_order, m.is_active,
            1 AS level
        FROM public.iam_menu m
        WHERE m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.order_num AS sort_order, m.is_active,
            mt.level + 1
        FROM public.iam_menu m
        JOIN menu_tree mt ON m.parent_id = mt.id
        WHERE m.is_active AND mt.level < 10
    )
    SELECT COALESCE(json_agg(json_build_object(
        'id', mt.id, 'parent_id', mt.parent_id, 'name', mt.name,
        'path', mt.path, 'icon', mt.icon, 'sort_order', mt.sort_order,
        'is_active', mt.is_active, 'level', mt.level
    ) ORDER BY mt.level, mt.sort_order, mt.id), '[]'::json) INTO v_result
    FROM menu_tree mt;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_menu_tree_admin() IS '获取完整菜单树形结构（管理用），按层级和排序（044: 源列 path→router）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_menu_tree_admin() TO authenticated;

-- 5.6 get_role_permissions（m.path → m.router，输出键 path 保持——角色授权弹窗契约）
DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(uuid);
DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(text);
CREATE FUNCTION api_v1_public.get_role_permissions(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role RECORD;
    v_apis json;
    v_menus json;
BEGIN
    SELECT id, name AS role_name, role_code, type, is_default INTO v_role
    FROM role WHERE role_code = p_role_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(json_agg(
        json_build_object('id', a.id, 'path', a.path, 'method', a.method, 'api_name', a.name)
        ORDER BY a.path
    ), '[]'::json) INTO v_apis
    FROM iam_role_api ra
    JOIN iam_api a ON ra.api_id = a.id
    WHERE ra.role_code = p_role_code AND a.is_active;

    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.menu_name, 'parent_id', m.parent_id,
                          'path', m.router, 'icon', m.icon)
        ORDER BY m.order_num
    ), '[]'::json) INTO v_menus
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active;

    RETURN json_build_object(
        'role_id', v_role.id,
        'role_code', v_role.role_code,
        'role_name', v_role.role_name,
        'type', v_role.type,
        'apis', v_apis,
        'menus', v_menus,
        'api_count', json_array_length(v_apis),
        'menu_count', json_array_length(v_menus)
    );
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_role_permissions(text) IS '获取角色权限（044: 菜单源列 path→router，输出键保持）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_role_permissions(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols     int;
    v_btn_pid  uuid;
    v_api_mid  uuid;
    v_leak     int;
    v_vcols    int;
BEGIN
    -- 列改名/新增
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu' AND column_name IN ('api_code','router');
    IF v_cols <> 2 THEN RAISE EXCEPTION '044: iam_menu 改名不完整（api_code/router 缺失）'; END IF;
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu' AND column_name IN ('perms','path');
    IF v_cols <> 0 THEN RAISE EXCEPTION '044: iam_menu 旧列名残留'; END IF;
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_api' AND column_name='order_num';
    IF v_cols <> 1 THEN RAISE EXCEPTION '044: iam_api.order_num 缺失'; END IF;

    -- 数据整理
    SELECT parent_id INTO v_btn_pid FROM iam_menu WHERE menu_name = 'UserAdd';
    IF v_btn_pid IS DISTINCT FROM (SELECT id FROM iam_menu WHERE menu_name='UserList' AND menu_type='directory') THEN
        RAISE EXCEPTION '044: UserAdd 未归位 UserList';
    END IF;
    SELECT menu_id INTO v_api_mid FROM iam_api WHERE api_code = 'sys:user:add';
    IF v_api_mid IS DISTINCT FROM (SELECT id FROM iam_menu WHERE menu_name='UserAdd') THEN
        RAISE EXCEPTION '044: sys:user:add 接口未挂 UserAdd 按钮';
    END IF;

    -- 函数体无残留旧列引用（表别名引用 m.path/m.perms）
    SELECT count(*) INTO v_leak FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname IN ('has_permission','rpc_create_menu','rpc_update_menu',
                        'get_user_menu','get_menu_tree_admin','get_role_permissions')
      AND (p.prosrc LIKE '%m.path%' OR p.prosrc LIKE '%m.perms%');
    IF v_leak <> 0 THEN RAISE EXCEPTION '044: 函数体残留 m.path/m.perms 引用（%）', v_leak; END IF;

    -- 视图列
    SELECT count(*) INTO v_vcols FROM information_schema.columns
    WHERE table_schema='api_v1_public' AND table_name='iam_menu' AND column_name IN ('router','api_code');
    IF v_vcols <> 2 THEN RAISE EXCEPTION '044: iam_menu 视图列未更新'; END IF;

    RAISE NOTICE '044: 全部验证通过（列改名+order_num+数据整理+6函数+3视图重建+权限补授）';
END $$;

-- ---------------------------------------------------------------------------
-- §7 PostgREST schema cache 刷新
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
