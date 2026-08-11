-- =============================================================================
-- 045_rpc_create_menu_with_api.sql — 合并创建 RPC（菜单+接口一次事务提交）
-- =============================================================================
-- 背景: 2026-08-09 用户拍板（资源树一体化方案；字段分析结论 ② 一致性兜底之"合并 RPC"）
--   前端"一个表单"体验：新建按钮（或菜单）时内嵌接口区，一次提交同时写 iam_menu + iam_api
-- 设计:
--   - rpc_create_menu_with_api = rpc_create_menu 全部参数 + 接口参数（p_api_path 填了才创建）
--   - 单码制: 接口 api_code 复用菜单参数 p_api_code（同一码，天然一致）
--   - 归属: 新建接口 menu_id = 新菜单 id（接口挂该节点下——按钮>接口 或 菜单>接口 均支持）
--   - 分组: p_api_group 留空默认取菜单名（与 rpc_create_api 043 同惯例）
--   - 权限门槛: sys:menu:create（创建菜单的权限即含同建接口）
--   - 事务: 单函数天然原子——任一失败整体回滚（含菜单）
-- 校验:
--   - 菜单侧: 同 rpc_create_menu（名称/类型/button api_code 必填 + 软校验 NOTICE）
--   - 接口侧: path+method 唯一、api_code 唯一（前置友好报错 22023，不依赖 UNIQUE 报错）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_menu_with_api(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_api_code text DEFAULT NULL, p_router text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL,
    -- 接口部分（p_api_path 非空才创建接口；api_code 复用 p_api_code——单码制）
    p_api_path text DEFAULT NULL, p_api_method text DEFAULT 'GET',
    p_api_name text DEFAULT NULL, p_api_description text DEFAULT NULL,
    p_api_group text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id      uuid;
    v_api_id  uuid;
    v_with_api boolean;
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

    v_with_api := p_api_path IS NOT NULL AND trim(p_api_path) <> '';

    -- 接口侧前置校验（友好报错，不依赖 UNIQUE 约束消息）
    IF v_with_api THEN
        IF p_api_method IS NULL OR trim(p_api_method) = '' THEN
            RAISE EXCEPTION 'api_method required' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM iam_api WHERE path = p_api_path AND method = p_api_method) THEN
            RAISE EXCEPTION 'api path+method duplicate' USING ERRCODE = '22023';
        END IF;
        IF p_api_code IS NOT NULL AND trim(p_api_code) <> ''
           AND EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_api_code) THEN
            RAISE EXCEPTION 'api_code already exists' USING ERRCODE = '22023';
        END IF;
    ELSIF p_api_code IS NOT NULL AND trim(p_api_code) <> ''
          AND NOT EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_api_code AND is_active) THEN
        -- 040 软校验：纯按钮场景，码应对应 iam_api.api_code（仅警告不阻断）
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

    IF v_with_api THEN
        INSERT INTO iam_api (path, method, name, description, api_code, is_active,
                             menu_id, api_group, order_num, created_by)
        VALUES (trim(p_api_path), upper(trim(p_api_method)),
                COALESCE(trim(p_api_name), p_menu_name), p_api_description,
                NULLIF(trim(p_api_code), ''), true,
                v_id, COALESCE(NULLIF(trim(p_api_group), ''), p_menu_name), 0,
                current_user_id())
        RETURNING id INTO v_api_id;
    END IF;

    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type,
                                                      'with_api', v_with_api));
    RETURN json_build_object('ok', true, 'id', v_id, 'api_id', v_api_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu_with_api(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, text, text, text) IS '菜单+接口合并创建（sys:menu:create；045: p_api_path 非空则同建接口挂新菜单下，api_code 单码制复用）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu_with_api(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 验证（smoke：超管创建测试按钮+接口 → 校验 → 清理）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_id     uuid;
    v_api_id uuid;
    v_res    json;
    v_ok     boolean;
BEGIN
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);

    -- 1. 正常路径：button + api
    v_res := api_v1_public.rpc_create_menu_with_api(
        p_menu_name => '__smoke_045__', p_menu_type => 'button',
        p_api_code => 'sys:smoke:045', p_router => null,
        p_api_path => '/rpc/sys:smoke:045', p_api_method => 'POST',
        p_api_name => '045 冒烟接口');
    v_id := (v_res->>'id')::uuid;
    v_api_id := (v_res->>'api_id')::uuid;
    IF v_id IS NULL OR v_api_id IS NULL THEN
        RAISE EXCEPTION '045: smoke 创建失败';
    END IF;
    SELECT (api_code = 'sys:smoke:045') AND (menu_id = v_id) INTO v_ok
    FROM iam_api WHERE id = v_api_id;
    IF v_ok IS NOT TRUE THEN
        RAISE EXCEPTION '045: 接口归属/单码制校验失败';
    END IF;

    -- 2. 拒绝路径：重复 path+method 报 22023
    BEGIN
        PERFORM api_v1_public.rpc_create_menu_with_api(
            p_menu_name => '__smoke_045_dup__', p_menu_type => 'button',
            p_api_code => 'sys:smoke:045x',
            p_api_path => '/rpc/sys:smoke:045', p_api_method => 'POST');
        RAISE EXCEPTION '045: 重复 path+method 未被拒绝';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL; -- 预期
    END;

    -- 清理
    DELETE FROM iam_api WHERE id = v_api_id;
    DELETE FROM iam_menu WHERE id = v_id;
    RAISE NOTICE '045: 全部验证通过（合并创建+单码制+唯一性拒绝）';
END $$;

NOTIFY pgrst, 'reload schema';
