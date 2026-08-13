-- =============================================================================
-- 056_iam_menu_query_drop_route_name_fallback.sql — 删 query 列 + route_name 自动推导兜底（B1/B2）
-- =============================================================================
-- 背景: 2026-08-13 用户拍板（B1 P1 / B2 P2；与前端 Q2 联动）:
--   B1 删除 iam_menu.query 列 + rpc_create/update_menu 的 p_query 参数 +
--      get_user_menu 的 query 输出——字段全空 + 前端死路由（前端不消费），纯清理无风险
--   B2 route_name 后端自动推导兜底（仿 SharpFort / vue-element-admin 惯例）:
--      router 末段首字母大写作路由 name（如 /system/user → User），手填值优先；
--      写侧兜底（仅 create/update RPC），不触碰存量数据——"不影响现有数据"
-- 决策:
--   B1 列/参数/输出三处同步删除；历史迁移 038/044/045/055 保持原样（055 前语义，
--      重放时 038 会 IF NOT EXISTS 重建列，056 末尾 DROP 收敛——幂等不变式）
--   B2 推导限制 directory/menu 两型（button 行 router 恒 NULL；link 行 router 是
--      外链 URL，末段推导无意义）；rpc_update_menu 改 router 未传 route_name 时重新推导
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（-query 列）→ 056 自带重建。⚠️ DROP COLUMN 前
--     必须先 DROP VIEW：PG 列级依赖会让 DROP COLUMN 报 2BP01（038/044 重放会
--     用含 query 的定义重建视图）
--   - public.get_user_menu（-query 输出）→ 056 自带重建。⚠️ 函数体是文本、列级
--     依赖不追踪，但 038/044 重放会用 m.query 版本覆盖 src 层新版——不重建则
--     列删后调用 42703
--   - rpc_create_menu / rpc_update_menu（新签名 18/19 参，去 p_query；旧签名
--     必须 DROP——PGRST203 重载歧义教训，含 024/038/055 全世代签名兜底）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同批提交）:
--   - db/api_v1/public/views/iam_menu.sql（-query）
--   - db/src/public/functions/get_user_menu.sql（-query）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 视图依赖解除 + 删列（B1；幂等）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_menu CASCADE;
ALTER TABLE public.iam_menu DROP COLUMN IF EXISTS query;

-- ---------------------------------------------------------------------------
-- §2 route_name 推导 helper（B2；router 末段首字母大写，无 router/空末段返回 NULL）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.derive_route_name(p_router text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
SELECT upper(left(s, 1)) || substring(s FROM 2)
FROM (
    SELECT (string_to_array(btrim(p_router, '/'), '/'))
           [array_length(string_to_array(btrim(p_router, '/'), '/'), 1)] AS s
) t
WHERE s IS NOT NULL AND s <> '';
$$;
COMMENT ON FUNCTION public.derive_route_name(text) IS '路由名称推导（056 B2：router 末段首字母大写，如 /system/user→User；仿 SharpFort/vue-element-admin 惯例；p_router 为 NULL 或末段为空返回 NULL）';

-- ---------------------------------------------------------------------------
-- §3 重建暴露视图（-query；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, is_link, is_iframe, redirect, keep_alive,
       api_url, api_method, is_affix,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（056: -query——字段全空+前端死路由，B1 清理）';
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT ALL ON api_v1_public.iam_menu TO super_admin;

-- ---------------------------------------------------------------------------
-- §4 重建 get_user_menu（-query 输出；与 src/public/functions/get_user_menu.sql 一致）
--     ⚠️ 必须自带重建：038/044 重放会用含 m.query 的旧版覆盖，列删后调用 42703
-- ---------------------------------------------------------------------------
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
            m.is_link, m.is_iframe, m.keep_alive, m.redirect, m.route_name,
            m.is_affix
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.keep_alive, m.redirect, m.route_name,
            m.is_affix
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
            c.is_link, c.is_iframe, c.keep_alive, c.redirect, c.route_name,
            c.is_affix,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（056: -query——字段全空+前端死路由 B1 清理；055: +is_affix——多页签固定标签，前端可选消费）';

-- ---------------------------------------------------------------------------
-- §5 重建 rpc_create_menu（B1 去 p_query → 18 参；B2 route_name 推导兜底）
--     旧签名全世代 DROP（024 9 参 / 038-044 16 参 / 055 19 参）防 PGRST203
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean);
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean);
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean);
CREATE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_api_code text DEFAULT NULL, p_router text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL,
    p_api_url text DEFAULT NULL, p_api_method text DEFAULT NULL, p_is_affix boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('public:menu:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_name IS NULL OR trim(p_menu_name) = '' THEN
        RAISE EXCEPTION 'menu_name required' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：button 必须 api_code
    IF p_menu_type = 'button' AND (p_api_code IS NULL OR trim(p_api_code) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：button 行禁传导航字段（RPC 友好报错 + 表级 CHECK 兜底）
    IF p_menu_type = 'button' AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    -- 端点仅 button 行使用（Admin.NET CheckMenuParam 语义：非 Btn 行不落端点）
    IF p_menu_type <> 'button' AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, api_code, router, component,
                          icon, order_num, is_visible,
                          remark, route_name,
                          is_link, is_iframe, redirect, keep_alive,
                          api_url, api_method, is_affix, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type,
            CASE WHEN p_menu_type = 'button' THEN p_api_code ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_router END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_component END,
            p_icon, p_order_num, p_is_visible,
            p_remark,
            -- 056 B2：手填优先；否则 directory/menu 行按 router 末段推导
            -- （button 行 router 恒 NULL、link 行 router 为外链 URL，均不推导）
            COALESCE(p_route_name,
                     CASE WHEN p_menu_type IN ('directory','menu')
                          THEN public.derive_route_name(p_router) END),
            COALESCE(p_is_link, p_menu_type = 'link'), COALESCE(p_is_iframe, false),
            p_redirect, COALESCE(p_keep_alive, true),
            CASE WHEN p_menu_type = 'button' THEN p_api_url ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN p_api_method ELSE NULL END,
            COALESCE(p_is_affix, false), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单新增（public:menu:create；056: -p_query（B1）+route_name 推导兜底（B2）；055: +api_url/api_method/is_affix，D8 button 禁导航字段，D6 端点成对值域）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 重建 rpc_update_menu（B1 去 p_query → 19 参；B2 route_name 推导兜底）
--     旧签名全世代 DROP（024 11 参 / 038-044 18 参 / 055 20 参）防 PGRST203
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean);
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean);
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean);
CREATE FUNCTION api_v1_public.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_api_code text DEFAULT NULL, p_router text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL,
    p_api_url text DEFAULT NULL, p_api_method text DEFAULT NULL, p_is_affix boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_api_code  text;
BEGIN
    IF NOT has_permission('public:menu:update') THEN
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
    SELECT menu_type, api_code INTO v_menu_type, v_api_code FROM iam_menu WHERE id = p_id;
    -- 040 单码制：最终类型为 button 必须 api_code
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (COALESCE(p_api_code, v_api_code) IS NULL OR trim(COALESCE(p_api_code, v_api_code)) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：最终类型为 button 禁传导航字段
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) <> 'button'::iam_menu_type)
       AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type::iam_menu_type, menu_type),
        -- 055：字段归属按最终类型（Admin.NET CheckMenuParam 语义）
        api_code    = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_code, api_code) ELSE NULL END,
        router      = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_router, router) END,
        component   = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_component, component) END,
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        remark      = COALESCE(p_remark, remark),
        -- 056 B2：button 行清空（导航字段族同 D8）；手填值优先；
        --         directory/menu 行改 router 未传 route_name 时按新 router 重新推导
        route_name  = CASE
            WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                THEN NULL
            WHEN p_route_name IS NOT NULL
                THEN p_route_name
            WHEN p_router IS NOT NULL
             AND COALESCE(p_menu_type::iam_menu_type, v_menu_type) IN ('directory'::iam_menu_type, 'menu'::iam_menu_type)
                THEN public.derive_route_name(p_router)
            ELSE route_name
        END,
        is_link     = COALESCE(p_is_link, p_menu_type = 'link', is_link),
        is_iframe   = COALESCE(p_is_iframe, is_iframe),
        redirect    = COALESCE(p_redirect, redirect),
        keep_alive  = COALESCE(p_keep_alive, keep_alive),
        api_url     = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_url, api_url) ELSE NULL END,
        api_method  = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_method, api_method) ELSE NULL END,
        is_affix    = COALESCE(p_is_affix, is_affix),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单修改（public:menu:update；056: -p_query（B1）+route_name 推导兜底/button 清空（B2）；055: +api_url/api_method/is_affix，字段归属按最终类型）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §7 验证 DO 块（结构 + 签名 + B1/B2 行为）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_query_col int;
    v_view_q    int;
    v_view_rn   int;
    v_c_cnt     int;
    v_c_args    int;
    v_u_args    int;
    v_c_query   int;
    v_u_query   int;
    v_id        uuid;
    v_derived   text;
    v_manual    text;
    v_upd_der   text;
    v_btn_rn    text;
    v_link_rn   text;
    v_menu      json;
    v_out_q     int;
    v_out_rn    int;
BEGIN
    -- 崩溃残留清理（幂等重放安全；先清审计行——target_id 引用测试菜单 id，
    --    不限 module：覆盖 log_operate 的 operate 行 + 审计触发器的 data_change 行）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    -- 1. B1 列删除断言
    SELECT count(*) INTO v_query_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'query';
    IF v_query_col <> 0 THEN
        RAISE EXCEPTION '056: iam_menu.query 未删除（%）', v_query_col;
    END IF;

    -- 2. 视图列断言（无 query、有 route_name）
    SELECT count(*) INTO v_view_q FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'query';
    SELECT count(*) INTO v_view_rn FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'route_name';
    IF v_view_q <> 0 OR v_view_rn <> 1 THEN
        RAISE EXCEPTION '056: 视图列异常（query=% route_name=%）', v_view_q, v_view_rn;
    END IF;

    -- 3. 签名断言（无重载残留 + 参数个数 + 无 p_query 参数名）
    SELECT count(*) INTO v_c_cnt FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu';
    IF v_c_cnt <> 1 THEN
        RAISE EXCEPTION '056: rpc_create_menu 重载残留（%）', v_c_cnt;
    END IF;
    SELECT pronargs INTO v_c_args FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu';
    SELECT pronargs INTO v_u_args FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu';
    IF v_c_args <> 18 OR v_u_args <> 20 THEN
        RAISE EXCEPTION '056: RPC 参数个数异常（create=% update=%）', v_c_args, v_u_args;
    END IF;
    SELECT count(*) INTO v_c_query FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_query' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_query FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_query' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    IF v_c_query <> 0 OR v_u_query <> 0 THEN
        RAISE EXCEPTION '056: p_query 参数残留（create=% update=%）', v_c_query, v_u_query;
    END IF;

    -- 4. B2 行为：创建推导 / 手填优先 / 改 router 重推导 / button+link 不推导
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);

    SELECT (api_v1_public.rpc_create_menu(
        '__t_derive__', NULL, 'menu', NULL, '/system/user', 'user/index'
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_derived FROM iam_menu WHERE id = v_id;
    IF v_derived IS DISTINCT FROM 'User' THEN
        RAISE EXCEPTION '056: route_name 推导失败（期望 User 实际 %）', v_derived;
    END IF;

    PERFORM api_v1_public.rpc_update_menu(
        p_id => v_id, p_router => '/system/keep', p_route_name => 'ManualName');
    SELECT route_name INTO v_manual FROM iam_menu WHERE id = v_id;
    IF v_manual <> 'ManualName' THEN
        RAISE EXCEPTION '056: 手填 route_name 未优先（%）', v_manual;
    END IF;

    PERFORM api_v1_public.rpc_update_menu(p_id => v_id, p_router => '/system/profile');
    SELECT route_name INTO v_upd_der FROM iam_menu WHERE id = v_id;
    IF v_upd_der IS DISTINCT FROM 'Profile' THEN
        RAISE EXCEPTION '056: 改 router 后重推导失败（%）', v_upd_der;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    SELECT (api_v1_public.rpc_create_menu(
        '__t_btn__', NULL, 'button', 'public:t:run', NULL, NULL, NULL, 0, true,
        NULL, NULL, NULL, NULL, NULL, NULL, '/rpc/t', 'POST', false
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_btn_rn FROM iam_menu WHERE id = v_id;
    IF v_btn_rn IS NOT NULL THEN
        RAISE EXCEPTION '056: button 行不应有 route_name（%）', v_btn_rn;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    SELECT (api_v1_public.rpc_create_menu(
        '__t_link__', NULL, 'link', NULL, 'https://example.com/docs', NULL,
        NULL, 0, true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_link_rn FROM iam_menu WHERE id = v_id;
    IF v_link_rn IS NOT NULL THEN
        RAISE EXCEPTION '056: link 行不应推导 route_name（%）', v_link_rn;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    -- 5. get_user_menu 输出断言（B1：无 query 键；route_name 键保留）
    SELECT get_user_menu() INTO v_menu;
    SELECT count(*) INTO v_out_q FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'query';
    SELECT count(*) INTO v_out_rn FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'route_name';
    IF v_out_q <> 0 OR v_out_rn = 0 THEN
        RAISE EXCEPTION '056: get_user_menu 输出异常（query=% route_name=%）', v_out_q, v_out_rn;
    END IF;

    -- 清理测试审计行与菜单行（先审计后菜单——审计 target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    RAISE NOTICE '056: 全部验证通过（query列=0 视图无query 签名 create=18/update=20 推导=User/Profile 手填优先 button/link不推导 输出无query）';
END $$;
