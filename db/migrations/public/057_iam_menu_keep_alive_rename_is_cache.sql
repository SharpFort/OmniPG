-- =============================================================================
-- 057_iam_menu_keep_alive_rename_is_cache.sql — keep_alive → is_cache 列改名
-- =============================================================================
-- 背景: 2026-08-13 用户拍板（B3）:
--   ① 语义对标 SharpFort IsCache / RuoYi is_cache（页面缓存语义）
--   ② iam_menu 布尔列命名统一——is_active/is_visible/is_link/is_iframe/is_affix
--      全部 is_ 前缀，keep_alive 是唯一例外
--   ⚠️ PG 列名用 is_cache 而非 C# 风格 IsCache：PG 未加引号标识符强制折叠小写
--      （IsCache 会变 iscache）；前端 Vue 路由 meta.keepAlive（art-page-content
--      消费）不改——Vue 生态惯例名，与 DB 字段已解耦
-- 决策:
--   列 keep_alive → is_cache（值随列保留，无数据迁移）；
--   rpc_create_menu / rpc_update_menu 参数 p_keep_alive → p_is_cache（统一 API 面）；
--   get_user_menu 输出键 keep_alive → is_cache（前端 MenuProcessor 映射同步一行）
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（is_cache）→ 057 自带重建
--   - public.get_user_menu（is_cache 输出键）→ 057 自带重建
--   - rpc_create_menu / rpc_update_menu（p_is_cache；签名类型不变 18/20 参）
-- ⚠️ RENAME 联动范围（023 教训）: RENAME COLUMN 自动更新视图/RLS 策略/触发器
--   （OID 依赖），但 PL/pgSQL 函数体是文本、不自动更新 → 必须重建 get_user_menu /
--   rpc_create_menu / rpc_update_menu，否则列改名后调用 42703
-- ⚠️ 重放收敛双分支（apply-src 全量重放架构）:
--   038 历史迁移重放会 IF NOT EXISTS 重建 keep_alive 列（NOT NULL DEFAULT true，
--   全默认值、无真实数据）→ 057 检测双列并存时 DROP 重建列（真实数据在 is_cache）；
--   首跑环境（仅 keep_alive 存在）走 RENAME 保留值
-- ⚠️ DROP 重建列前必须先 DROP VIEW（PG 列级依赖 2BP01——038/044/056 重放会
--   用含 keep_alive 的定义重建视图）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同批提交）:
--   - db/api_v1/public/views/iam_menu.sql（keep_alive → is_cache）
--   - db/src/public/functions/get_user_menu.sql（keep_alive → is_cache）
-- 历史迁移 038/040/044/045/055/056 保持原样（各自时代语义；056 前形态引用
--   keep_alive 列在重放时由 038 重建、057 收敛——幂等不变式）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 视图依赖解除（幂等；DROP 重建列前必须）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_menu CASCADE;

-- ---------------------------------------------------------------------------
-- §2 列改名双分支收敛（幂等）
--     首跑：仅 keep_alive 存在 → RENAME（NOT NULL DEFAULT true 等约束随列走）
--     重放：keep_alive + is_cache 并存 → 038 重建了 keep_alive（全默认值）→ DROP
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'iam_menu'
                 AND column_name = 'keep_alive')
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'iam_menu'
                     AND column_name = 'is_cache') THEN
        -- 重放环境：keep_alive 为 038 重放重建（全默认值 true，无真实数据），删除
        ALTER TABLE public.iam_menu DROP COLUMN keep_alive;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'iam_menu'
                    AND column_name = 'keep_alive') THEN
        -- 首跑环境：改名，值随列保留
        ALTER TABLE public.iam_menu RENAME COLUMN keep_alive TO is_cache;
    END IF;
END $$;

COMMENT ON COLUMN public.iam_menu.is_cache IS '是否缓存页面（keep-alive，默认 true；057 由 keep_alive 改名——语义对标 SharpFort IsCache/RuoYi is_cache + iam_menu 布尔列 is_ 前缀命名统一）';

-- ---------------------------------------------------------------------------
-- §3 重建暴露视图（is_cache；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, api_code, router, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, is_link, is_iframe, redirect, is_cache,
       api_url, api_method, is_affix,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（057: keep_alive→is_cache 改名——SharpFort IsCache 语义 + is_ 前缀统一；056: -query）';
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT ALL ON api_v1_public.iam_menu TO super_admin;

-- ---------------------------------------------------------------------------
-- §4 重建 get_user_menu（输出键 is_cache；与 src/public/functions/get_user_menu.sql 一致）
--     ⚠️ 必须自带重建：PL/pgSQL 函数体不随 RENAME 自动更新，否则调用 42703
--     ⚠️ 输出键变化 = 前端契约变化：MenuProcessor 读 menu.is_cache → meta.keepAlive
--        （Vue 侧 meta.keepAlive 本身不改）
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
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
            m.is_affix
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.router AS path, m.icon,
            m.menu_type, m.api_code AS perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.is_cache, m.redirect, m.route_name,
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
            c.is_link, c.is_iframe, c.is_cache, c.redirect, c.route_name,
            c.is_affix,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（057: keep_alive→is_cache 输出键——前端 MenuProcessor 映射同步，Vue meta.keepAlive 不改；056: -query B1 清理）';

-- ---------------------------------------------------------------------------
-- §5 重建 rpc_create_menu（p_keep_alive → p_is_cache；签名类型不变 18 参）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean);
CREATE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_api_code text DEFAULT NULL, p_router text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_is_cache boolean DEFAULT NULL,
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
                          is_link, is_iframe, redirect, is_cache,
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
            p_redirect, COALESCE(p_is_cache, true),
            CASE WHEN p_menu_type = 'button' THEN p_api_url ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN p_api_method ELSE NULL END,
            COALESCE(p_is_affix, false), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单新增（public:menu:create；057: p_keep_alive→p_is_cache；056: -p_query +route_name 推导兜底；055: +api_url/api_method/is_affix）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 重建 rpc_update_menu（p_keep_alive → p_is_cache；签名类型不变 20 参）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean);
CREATE FUNCTION api_v1_public.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_api_code text DEFAULT NULL, p_router text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_is_cache boolean DEFAULT NULL,
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
        is_cache    = COALESCE(p_is_cache, is_cache),
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
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单修改（public:menu:update；057: p_keep_alive→p_is_cache；056: -p_query +route_name 推导兜底/button 清空；055: 字段归属按最终类型）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §7 验证 DO 块（结构 + 参数名 + 行为）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ka_col    int;
    v_ic_col    int;
    v_view_ka   int;
    v_view_ic   int;
    v_c_ka      int;
    v_c_ic      int;
    v_u_ka      int;
    v_u_ic      int;
    v_id        uuid;
    v_def_ic    boolean;
    v_set_ic    boolean;
    v_menu      json;
    v_out_ka    int;
    v_out_ic    int;
BEGIN
    -- 崩溃残留清理（幂等重放安全；先清审计行——target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    -- 1. 列断言（keep_alive 无、is_cache 有）
    SELECT count(*) INTO v_ka_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'keep_alive';
    SELECT count(*) INTO v_ic_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'is_cache';
    IF v_ka_col <> 0 OR v_ic_col <> 1 THEN
        RAISE EXCEPTION '057: 列状态异常（keep_alive=% is_cache=%）', v_ka_col, v_ic_col;
    END IF;

    -- 2. 视图列断言
    SELECT count(*) INTO v_view_ka FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'keep_alive';
    SELECT count(*) INTO v_view_ic FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'is_cache';
    IF v_view_ka <> 0 OR v_view_ic <> 1 THEN
        RAISE EXCEPTION '057: 视图列异常（keep_alive=% is_cache=%）', v_view_ka, v_view_ic;
    END IF;

    -- 3. RPC 参数名断言（p_keep_alive 无、p_is_cache 有）
    SELECT count(*) INTO v_c_ka FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_keep_alive' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_c_ic FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_is_cache' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_ka FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_keep_alive' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_ic FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_is_cache' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    IF v_c_ka <> 0 OR v_c_ic <> 1 OR v_u_ka <> 0 OR v_u_ic <> 1 THEN
        RAISE EXCEPTION '057: 参数名异常（c_ka=% c_ic=% u_ka=% u_ic=%）', v_c_ka, v_c_ic, v_u_ka, v_u_ic;
    END IF;

    -- 4. 行为：p_is_cache 默认 true / 显式 false；update 同
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    SELECT (api_v1_public.rpc_create_menu(
        '__t_cache__', NULL, 'menu', NULL, '/system/cache-t', 'cache/index'
    )->>'id')::uuid INTO v_id;
    SELECT is_cache INTO v_def_ic FROM iam_menu WHERE id = v_id;
    IF v_def_ic IS NOT TRUE THEN
        RAISE EXCEPTION '057: p_is_cache 默认值异常（%）', v_def_ic;
    END IF;
    PERFORM api_v1_public.rpc_update_menu(p_id => v_id, p_is_cache => false);
    SELECT is_cache INTO v_set_ic FROM iam_menu WHERE id = v_id;
    IF v_set_ic IS NOT FALSE THEN
        RAISE EXCEPTION '057: p_is_cache=false 更新异常（%）', v_set_ic;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    -- 5. get_user_menu 输出键断言（is_cache 有、keep_alive 无）
    SELECT get_user_menu() INTO v_menu;
    SELECT count(*) INTO v_out_ka FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'keep_alive';
    SELECT count(*) INTO v_out_ic FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'is_cache';
    IF v_out_ka <> 0 OR v_out_ic = 0 THEN
        RAISE EXCEPTION '057: get_user_menu 输出键异常（keep_alive=% is_cache=%）', v_out_ka, v_out_ic;
    END IF;

    -- 清理测试审计行与菜单行（先审计后菜单——审计 target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    RAISE NOTICE '057: 全部验证通过（列/视图/参数名改名生效 行为 p_is_cache 默认true/显式false 输出键 is_cache）';
END $$;
