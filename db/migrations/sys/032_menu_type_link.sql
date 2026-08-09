-- =============================================================================
-- 032_menu_type_link.sql — iam_menu_type 补充 link 值（统一外部链接/iframe）
-- =============================================================================
-- 背景: 2026-08-05 用户决策
--   menu_type 补充 'link' 统一"外部链接 + iframe 内嵌"两类场景
--   → 四值封闭（directory/menu/button/link），未来几乎不再变动
-- 关键坑（已规避）:
--   - ALTER TYPE ADD VALUE 无 IF NOT EXISTS → DO 块检查 + 动态执行（幂等）
--   - PG12+ 新值不能在同一事务内使用 → psql autocommit 逐语句提交，
--     验证 DO 块（独立事务）可安全使用 'link'
-- 联动:
--   - rpc_create_menu / rpc_update_menu 的 IN 校验加 'link'（否则前端传 link 被友好层拒绝）
--   - 类型/列注释更新
-- 语义: link 类型 = path 为 http(s):// 外部链接或 iframe 内嵌 URL；component 留空
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 ADD VALUE 'link'（幂等：DO 块检查 + 动态执行）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'iam_menu_type' AND e.enumlabel = 'link'
    ) THEN
        ALTER TYPE iam_menu_type ADD VALUE 'link';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §1 联动重建：rpc_create_menu / rpc_update_menu（IN 校验 4 值）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_perms text DEFAULT NULL, p_path text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0)
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
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, perms, path, component,
                          icon, order_num, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type, p_perms, p_path,
            p_component, p_icon, p_order_num, current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int) IS '菜单新增（sys:menu:create；menu_type: directory/menu/button/link，032 link 化）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_menu(
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
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) IS '菜单修改（sys:menu:update；032 link 化）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §2 注释更新
-- ---------------------------------------------------------------------------
COMMENT ON TYPE iam_menu_type IS '菜单类型（少变复用枚举，05.1 D-B 实例）：directory=目录 / menu=菜单 / button=按钮 / link=外链或iframe（path 为 URL，component 留空）';
COMMENT ON COLUMN public.iam_menu.menu_type IS '菜单类型: directory(目录) / menu(菜单) / button(按钮) / link(外链或iframe，032)';

-- ---------------------------------------------------------------------------
-- §3 验证（独立事务使用新值；幂等断言）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_link     int;
    v_fn       int;
    v_bad      boolean;
BEGIN
    SELECT count(*) INTO v_link FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'iam_menu_type' AND e.enumlabel = 'link';

    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('rpc_create_menu','rpc_update_menu')
        AND prosrc LIKE '%link%';

    -- 新值可用性（psql autocommit 独立事务）
    IF 'link'::iam_menu_type IS NULL OR v_link <> 1 THEN
        RAISE EXCEPTION '032 验证失败: link 值不可用';
    END IF;
    IF v_fn <> 2 THEN
        RAISE EXCEPTION '032 验证失败: 函数未联动';
    END IF;
    RAISE NOTICE '032: link 值=%（期望1） 函数联动=%（期望2） — 全部验证通过', v_link, v_fn;
END $$;
