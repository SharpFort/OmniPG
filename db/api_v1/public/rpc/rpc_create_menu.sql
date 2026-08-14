-- api_v1/public/rpc/rpc_create_menu.sql
-- FUNCTION: api_v1_public.rpc_create_menu（17 号文档归位：迁移 057_iam_menu_keep_alive_rename_is_cache.sql 删定义段，本文件为唯一权威）
-- 回放终态: 057_iam_menu_keep_alive_rename_is_cache.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_menu(
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
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;
