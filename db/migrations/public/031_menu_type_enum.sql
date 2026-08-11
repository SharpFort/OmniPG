-- =============================================================================
-- 031_menu_type_enum.sql — menu_type PG ENUM 化（05.1 D-B 实例：少变复用枚举）
-- =============================================================================
-- 背景: 2026-08-05 用户决策（前端联调期间）
--   menu_type 值集合极小（directory/menu/button）且几乎不变 → PG ENUM 适用场景
--   当前为 text 无表级约束（仅 024 RPC 内校验）→ ENUM 补表级强约束
-- 联动:
--   - 024 rpc_create_menu / rpc_update_menu：text 参数 → 显式 ::iam_menu_type
--     （text→enum 无隐式 cast，不重建会类型报错；函数内 IN 校验保留=前端友好报错）
--   - 011 种子默认 'menu'（历史）→ 031 转换后 DEFAULT 保留
-- 幂等: DO 块条件建类型 + ALTER TYPE 重复执行安全（enum→enum cast 自身）
-- 限制说明: PG ENUM 不能删值（本场景删除概率≈0）；PG18 支持事务内 ADD VALUE
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §0 类型创建（幂等）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'iam_menu_type') THEN
        CREATE TYPE iam_menu_type AS ENUM ('directory', 'menu', 'button');
    END IF;
END $$;
COMMENT ON TYPE iam_menu_type IS '菜单类型（少变复用枚举，05.1 D-B 实例）：directory=目录 / menu=菜单 / button=按钮';

-- ---------------------------------------------------------------------------
-- §1 列转换（幂等：text → enum）
--    031 补: 依赖 iam_menu 表的视图（api_v1_public.iam_menu/v_role_menu_detail/
--    v_system_stats + public.casbin_rule）先 DROP，ALTER 后按源文件逐字重建
--    （apply-src 顺序 src→api_v1→init→migrations，迁移须自带重建段）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_menu CASCADE;
DROP VIEW IF EXISTS api_v1_public.v_role_menu_detail CASCADE;
DROP VIEW IF EXISTS api_v1_public.v_system_stats CASCADE;
DROP VIEW IF EXISTS public.casbin_rule CASCADE;
ALTER TABLE iam_menu ALTER COLUMN menu_type DROP DEFAULT;
ALTER TABLE iam_menu ALTER COLUMN menu_type TYPE iam_menu_type
    USING menu_type::iam_menu_type;
ALTER TABLE iam_menu ALTER COLUMN menu_type SET DEFAULT 'menu'::iam_menu_type;

-- 031 补: 重建 iam_menu 视图（与 views/iam_menu.sql 逐字一致）+ 授权兜底
CREATE OR REPLACE VIEW api_v1_public.iam_menu AS
SELECT id, parent_id, menu_name, menu_type, perms, path, component, icon,
       order_num, is_visible, is_active,
       created_at, updated_at, created_by, updated_by
FROM public.iam_menu;
COMMENT ON VIEW api_v1_public.iam_menu IS '菜单表视图';
GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
GRANT ALL ON api_v1_public.iam_menu TO super_admin;

-- 031 补: 重建 v_role_menu_detail（与 views/v_role_menu_detail.sql 逐字一致）
DROP VIEW IF EXISTS api_v1_public.v_role_menu_detail CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_menu_detail AS
SELECT
    rm.id AS role_id,
    rm.menu_id,
    rm.created_at,
    rm.role_code,
    COALESCE(r.name, rm.role_code) AS role_name,
    m.menu_name AS menu_name,
    m.menu_type AS menu_type,
    m.perms AS permission_code,
    m.path AS menu_path,
    m.icon AS menu_icon,
    m.parent_id AS menu_parent_id
FROM iam_role_menu rm
JOIN role r ON r.role_code = rm.role_code
JOIN iam_menu m ON m.id = rm.menu_id;
COMMENT ON VIEW api_v1_public.v_role_menu_detail IS '角色-菜单明细视图（Logto 镜像：iam_role_menu）';
GRANT SELECT ON api_v1_public.v_role_menu_detail TO authenticated;
GRANT ALL ON api_v1_public.v_role_menu_detail TO super_admin;

-- 031 补: 重建 v_system_stats（与 views/v_system_stats.sql 逐字一致）
DROP VIEW IF EXISTS api_v1_public.v_system_stats CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_system_stats AS
SELECT
    (SELECT COUNT(*) FROM public.tenants WHERE deleted_at IS NULL) AS total_tenants,
    (SELECT COUNT(*) FROM public.users WHERE is_suspended = FALSE) AS active_users,
    (SELECT COUNT(*) FROM public.users) AS total_users,
    (SELECT COUNT(*) FROM public.role) AS total_roles,
    (SELECT COUNT(*) FROM public.department WHERE deleted_at IS NULL) AS total_departments,
    (SELECT COUNT(*) FROM public.iam_menu WHERE is_active) AS total_menus,
    (SELECT COUNT(*) FROM public.iam_api WHERE is_active) AS total_apis,
    now() AS stats_time;
COMMENT ON VIEW api_v1_public.v_system_stats IS '系统统计面板视图（单行汇总，Logto 镜像表）';
GRANT SELECT ON api_v1_public.v_system_stats TO authenticated;
GRANT ALL ON api_v1_public.v_system_stats TO super_admin;

-- 031 补: 重建 public.casbin_rule（与 src/public/views/casbin_rule.sql 逐字一致；035 保留）
CREATE OR REPLACE VIEW casbin_rule AS
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
WHERE a.is_active
UNION ALL
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    rm.role_code::varchar AS v0,
    m.path::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active;
COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（Role-in-JWT 简化版，仅 p 规则）：API 路由 + 菜单授权，自动过滤非激活项';

-- ---------------------------------------------------------------------------
-- §2 联动重建：rpc_create_menu / rpc_update_menu（text 参数显式 cast）
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
    IF p_menu_type NOT IN ('directory','menu','button') THEN
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
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int) IS '菜单新增（sys:menu:create；menu_type: directory/menu/button，031 enum 化）';
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
    IF p_menu_type IS NOT NULL AND p_menu_type NOT IN ('directory','menu','button') THEN
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
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) IS '菜单修改（sys:menu:update；031 enum 化）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_type     text;
    v_default  text;
    v_fn       int;
    v_invalid  boolean;
BEGIN
    SELECT t.typname INTO v_type
    FROM pg_type t JOIN pg_attribute a ON a.atttypid = t.oid
    WHERE a.attrelid = 'iam_menu'::regclass AND a.attname = 'menu_type';
    SELECT pg_get_expr(d.adbin, d.adrelid)::text INTO v_default
    FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    WHERE d.adrelid = 'iam_menu'::regclass AND a.attname = 'menu_type';

    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('rpc_create_menu','rpc_update_menu')
        AND prosrc LIKE '%::iam_menu_type%';

    -- 非法值表级拒绝验证（enum 强约束）
    BEGIN
        INSERT INTO iam_menu (menu_name, menu_type) VALUES ('__test_invalid__', 'bad_type');
        v_invalid := false;  -- 不应到达
        DELETE FROM iam_menu WHERE menu_name = '__test_invalid__';
    EXCEPTION WHEN invalid_text_representation THEN
        v_invalid := true;
    END;

    RAISE NOTICE '031: 列类型=%（期望 iam_menu_type） 默认=%（期望 iam_menu_type） 函数cast=%（期望2） 非法值拒绝=%（期望 true）',
        v_type, v_default, v_fn, v_invalid;

    IF v_type <> 'iam_menu_type' OR v_fn <> 2 OR NOT v_invalid THEN
        RAISE EXCEPTION '031 验证失败';
    END IF;
    RAISE NOTICE '031: 全部验证通过';
END $$;
