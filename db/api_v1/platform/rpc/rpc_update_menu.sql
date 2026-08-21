-- api_v1/platform/rpc/rpc_update_menu.sql
-- FUNCTION: api_v1_platform.rpc_update_menu（17 号文档归位：迁移 057_iam_menu_keep_alive_rename_is_cache.sql 删定义段，本文件为唯一权威）
-- 回放终态: 057_iam_menu_keep_alive_rename_is_cache.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_api_code text DEFAULT NULL, p_router text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_is_cache boolean DEFAULT NULL,
    p_api_url text DEFAULT NULL, p_api_method text DEFAULT NULL, p_is_affix boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_api_code  text;
BEGIN
    IF NOT has_permission('platform:menu:update') THEN
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
                THEN platform.derive_route_name(p_router)
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
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;
