-- =============================================================================
-- 038_iam_menu_nav_fields.sql — iam_menu 导航元字段补齐（P0，2026-08-09 用户拍板）
-- =============================================================================
-- 背景: 菜单/API 管理优化分析（对照 RuoYi sys_menu 14 字段 / SharpFort Menu.cs /
--       Art Design Pro RouteMeta 三方交集）结论落地
-- 决策（用户拍板）:
--   D1 7 个导航字段全要: remark / route_name / query / is_link / is_iframe /
--                       redirect / keep_alive
--   D2 保持 menu/api 分离式（不合并表）: iam_menu 管导航，iam_api 管权限点目录，
--      角色绑定走 iam_role_menu / iam_role_api（039 起 iam_api.menu_id 归属关联）
--   D3 menu_type='link' 强制 path 为 http(s)://（033 已按此回填，本迁移补表级 CHECK）
--   D4 button 类型 perms 必填 → 040 单码制迁移（先回填再建约束）
-- 修复: 035 重建 rpc_create_menu 时 IN 校验丢失 'link'（032 四值 → 035 三值回归，
--       前端传 link 会被友好层拒绝），本迁移重建时恢复四值
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（+7 列）
--   - public.get_user_menu（+is_link/is_iframe/keep_alive/redirect/query/route_name）
--   - rpc_create_menu / rpc_update_menu（新签名，旧签名必须 DROP——PGRST203 教训）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同步）:
--   - db/api_v1/public/views/iam_menu.sql
--   - db/src/public/functions/get_user_menu.sql
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_menu 加列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_menu
    ADD COLUMN IF NOT EXISTS remark     text,
    ADD COLUMN IF NOT EXISTS route_name text,        -- Vue Router name（英文唯一标识）
    ADD COLUMN IF NOT EXISTS query      text,        -- 路由参数（如 tab=1 或 ?a=1&b=2）
    ADD COLUMN IF NOT EXISTS is_link    boolean NOT NULL DEFAULT false,  -- 外链（新窗口打开）
    ADD COLUMN IF NOT EXISTS is_iframe  boolean NOT NULL DEFAULT false,  -- iframe 内嵌页面
    ADD COLUMN IF NOT EXISTS redirect   text,        -- 目录重定向（noRedirect 或子路径）
    ADD COLUMN IF NOT EXISTS keep_alive boolean NOT NULL DEFAULT true;   -- 页面缓存（keep-alive）

COMMENT ON COLUMN public.iam_menu.remark     IS '备注（管理端展示）';
COMMENT ON COLUMN public.iam_menu.route_name IS '路由名称（Vue Router name，英文唯一；前端 addRoute 用）';
COMMENT ON COLUMN public.iam_menu.query      IS '路由参数（如 tab=1；RuoYi sys_menu.query 同语义）';
COMMENT ON COLUMN public.iam_menu.is_link    IS '是否外链（新窗口打开；menu_type=link 时自动置 true）';
COMMENT ON COLUMN public.iam_menu.is_iframe  IS '是否 iframe 内嵌（path 为内嵌 URL）';
COMMENT ON COLUMN public.iam_menu.redirect   IS '目录重定向路径（noRedirect 表示不重定向）';
COMMENT ON COLUMN public.iam_menu.keep_alive IS '是否缓存页面（keep-alive，默认 true；RuoYi is_cache 同语义）';

-- ---------------------------------------------------------------------------
-- §2 表级 CHECK 约束（幂等 DO 块；D3）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_link_path_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_link_path_check
        CHECK (menu_type <> 'link' OR path LIKE 'http://%' OR path LIKE 'https://%');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_is_link_path_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_is_link_path_check
        CHECK (NOT is_link OR path LIKE 'http://%' OR path LIKE 'https://%');
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §3 种子回填（幂等：仅补 NULL；历史数据无外链 → 新列默认值即正确值）
--    button perms 回填在 040（单码制迁移，与 has_permission 双通道一起提交）
-- ---------------------------------------------------------------------------
-- （无回填语句：remark/route_name/query/redirect 留空由管理端配置，
--   is_link/is_iframe=false、keep_alive=true 为默认值）

-- ---------------------------------------------------------------------------
-- §4 重建暴露视图（+7 列；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_menu CASCADE;
CREATE OR REPLACE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, perms, path, component, icon,
       order_num, is_visible, is_active,
       remark, route_name, query, is_link, is_iframe, redirect, keep_alive,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图（038: +remark/route_name/query/is_link/is_iframe/redirect/keep_alive）';
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT ALL ON api_v1_public.iam_menu TO super_admin;

-- ---------------------------------------------------------------------------
-- §5 重建 get_user_menu（+导航元字段；与 src/public/functions/get_user_menu.sql 一致）
--    前端 MenuProcessor: is_link 直判外链（不再靠 path LIKE http% hack），
--    keep_alive → meta.keepAlive，redirect/query/route_name 按需消费
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
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.menu_type, m.perms, m.is_visible, m.component, m.order_num,
            m.is_link, m.is_iframe, m.keep_alive, m.redirect, m.query, m.route_name
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.menu_type, m.perms, m.is_visible, m.component, m.order_num,
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
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（038: +is_link/is_iframe/keep_alive/redirect/query/route_name——前端外链判改用 is_link 直判，keep_alive→meta.keepAlive）';

-- ---------------------------------------------------------------------------
-- §6 重建 rpc_create_menu / rpc_update_menu（新签名 16/18 参；035 回归修复）
--    旧签名必须 DROP（PostgREST 按参数名解析，重载共存会 PGRST203 歧义）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean);
CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_perms text DEFAULT NULL, p_path text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL)
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
    -- 038 修复: 035 回归丢 'link'（032 四值封闭）
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, perms, path, component,
                          icon, order_num, is_visible,
                          remark, route_name, query,
                          is_link, is_iframe, redirect, keep_alive, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type, p_perms, p_path,
            p_component, p_icon, p_order_num, p_is_visible,
            p_remark, p_route_name, p_query,
            COALESCE(p_is_link, p_menu_type = 'link'), COALESCE(p_is_iframe, false),
            p_redirect, COALESCE(p_keep_alive, true), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单新增（sys:menu:create；menu_type: directory/menu/button/link；038: +导航元字段，link 自动 is_link=true，修复 035 link 校验回归）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean);
CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_perms text DEFAULT NULL, p_path text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type::iam_menu_type, menu_type),
        perms       = COALESCE(p_perms, perms),
        path        = COALESCE(p_path, path),
        component   = COALESCE(p_component, component),
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        remark      = COALESCE(p_remark, remark),
        route_name  = COALESCE(p_route_name, route_name),
        query       = COALESCE(p_query, query),
        -- 改类型为 link 时自动置 is_link；改离 link 时仅显式传 false 才清
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
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单修改（sys:menu:update；038: +导航元字段，改 link 自动 is_link=true，修复 035 link 校验回归）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6.5 log_operate 修复（既有 P0 bug，冒烟暴露 2026-08-09）
--     audit_log.operation 列 001 建表即 NOT NULL，但 024 log_operate 的
--     INSERT 从未写入该列 → 所有写 RPC（menu/role-api/role-menu/...）审计
--     链路报 23502，写操作整体失败——前端菜单管理"不理想"的直接原因之一
--     修复: operation := p_action（业务动作标识，如 create/update/delete/bind）
--     无源文件（src/functions 无 log_operate.sql，024 起仅在迁移层定义）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_operate(p_module text, p_action text, p_target_type text DEFAULT NULL::text, p_target_id text DEFAULT NULL::text, p_result text DEFAULT 'success'::text, p_detail jsonb DEFAULT NULL::jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO audit_log
        (log_type, operation, module, action, target_type, target_id, result,
         new_data, user_id, tenant_id, created_at)
    VALUES
        ('operate', COALESCE(p_action, 'operate'), p_module, p_action,
         p_target_type, p_target_id, p_result,
         p_detail, current_user_id(), current_tenant_id(), now());
END;
$$;
COMMENT ON FUNCTION log_operate(text, text, text, text, text, jsonb) IS '业务操作审计写入（038 修复: +operation 列——audit_log.operation NOT NULL，024 起缺失导致写 RPC 23502）';

-- ---------------------------------------------------------------------------
-- §7 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols       int;
    v_checks     int;
    v_fn_link    int;
    v_fn_menu    int;
    v_link_ok    boolean;
    v_bad_type   boolean;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu'
      AND column_name IN ('remark','route_name','query','is_link','is_iframe','redirect','keep_alive');
    SELECT count(*) INTO v_checks FROM pg_constraint
    WHERE conname IN ('iam_menu_link_path_check','iam_menu_is_link_path_check');
    SELECT count(*) INTO v_fn_link FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('rpc_create_menu','rpc_update_menu')
        AND prosrc LIKE '%link%';

    -- CHECK 约束生效验证：非法 link（非 http path）拒绝
    BEGIN
        INSERT INTO iam_menu (menu_name, menu_type, path) VALUES ('__test_bad_link__', 'link', 'not-a-url');
        v_link_ok := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_bad_link__';
    EXCEPTION WHEN check_violation THEN
        v_link_ok := true;
    END;

    -- 枚举拒绝验证（032 语义回归防护）
    BEGIN
        INSERT INTO iam_menu (menu_name, menu_type) VALUES ('__test_bad_type__', 'bad_type');
        v_bad_type := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_bad_type__';
    EXCEPTION WHEN invalid_text_representation THEN
        v_bad_type := true;
    END;

    -- get_user_menu 新字段返回验证（伪 claims：role_super_admin 绑全部菜单）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    SELECT count(*) INTO v_fn_menu FROM json_array_elements(get_user_menu()::json) e
    WHERE e->>'name' = 'System' AND (e::jsonb) ? 'is_link' AND (e::jsonb) ? 'keep_alive';

    RAISE NOTICE '038: 新列=%（期望7） 约束=%（期望2） 函数link校验=%（期望2） link拒绝=%（期望true） 枚举拒绝=%（期望true） get_user_menu字段=%（期望1）',
        v_cols, v_checks, v_fn_link, v_link_ok, v_bad_type, v_fn_menu;

    IF v_cols <> 7 OR v_checks <> 2 OR v_fn_link <> 2 OR v_link_ok IS NOT TRUE OR v_bad_type IS NOT TRUE OR v_fn_menu <> 1 THEN
        RAISE EXCEPTION '038 验证失败';
    END IF;
    RAISE NOTICE '038: 全部验证通过';
END $$;
