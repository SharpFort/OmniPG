-- =============================================================================
-- 040_iam_single_code_perms.sql — 单码制 2-A：has_permission 双通道 + 按钮 perms 强制
-- =============================================================================
-- 背景: 菜单/API 管理优化结论落地（建议 2，用户选 2-A 单码制，2026-08-09 拍板）
--   现状断裂: iam_menu.button.perms 与 iam_api.api_code 两套并行体系——
--   has_permission 只查 api_code（通道1），前端按钮显隐读 menu.perms（通道2），
--   实测 3 个 button perms 全 NULL、8 个菜单 perms 全 NULL → 按钮级权限是摆设
-- 决策（RuoYi 单码制心智: 一个 system:user:add 既给按钮又做后端判定）:
--   D1 has_permission 双通道: claims roles ∩ (role_api→api_code ∪ role_menu→menu.perms)
--   D2 button 菜单 perms 必填（表级 CHECK + RPC 硬校验）
--   D3 按钮码与权限点同体系: 回填 UserAdd/UserEdit/UserDelete = sys:user:add/edit/delete，
--      同步赋给 /sys_user 端点（GET/POST/PATCH/DELETE）+ /rpc/kick_user
--   D4 软校验: RPC 传 perms 时若 iam_api.api_code 无对应 → NOTICE 警告不阻断
--      （新按钮码可先建权限点后配按钮，或反之；一致性靠管理端 UI 提示）
-- 联动: rpc_create_menu/rpc_update_menu 重建（038 签名不变，仅加校验逻辑）
-- 源文件: 无（has_permission 023 起仅在迁移层定义；src/functions 无此文件）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 种子回填（幂等：仅补 NULL；D3）
-- ---------------------------------------------------------------------------
UPDATE public.iam_menu SET perms = 'sys:user:add'
WHERE menu_name = 'UserAdd' AND perms IS NULL;
UPDATE public.iam_menu SET perms = 'sys:user:edit'
WHERE menu_name = 'UserEdit' AND perms IS NULL;
UPDATE public.iam_menu SET perms = 'sys:user:delete'
WHERE menu_name = 'UserDelete' AND perms IS NULL;

-- /sys_user 端点赋码（与按钮码同体系；历史死端点，保留供授权语义对齐）
UPDATE public.iam_api SET api_code = 'sys:user:list'
WHERE path = '/sys_user' AND method = 'GET' AND api_code IS NULL;
UPDATE public.iam_api SET api_code = 'sys:user:add'
WHERE path = '/sys_user' AND method = 'POST' AND api_code IS NULL;
UPDATE public.iam_api SET api_code = 'sys:user:edit'
WHERE path = '/sys_user' AND method = 'PATCH' AND api_code IS NULL;
UPDATE public.iam_api SET api_code = 'sys:user:delete'
WHERE path = '/sys_user' AND method = 'DELETE' AND api_code IS NULL;
UPDATE public.iam_api SET api_code = 'sys:user:kick'
WHERE path = '/rpc/kick_user' AND api_code IS NULL;

-- ---------------------------------------------------------------------------
-- §2 表级 CHECK：button 必须 perms（D2；回填完成后才建）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_button_perms_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_button_perms_check
        CHECK (menu_type <> 'button' OR (perms IS NOT NULL AND trim(perms) <> ''));
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §3 has_permission 双通道（D1；单码制核心）
--    通道1: iam_role_api → iam_api.api_code（原路径，23 定义）
--    通道2: iam_role_menu → iam_menu.perms（按钮权限码，40 新增）
--    超管短路不变；判定零查询（claims）+ 小表索引
-- ---------------------------------------------------------------------------
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

    -- 双通道：API 权限点（api_code）∪ 菜单按钮权限码（menu.perms）
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
          AND m.perms = p_code
          AND m.is_active
    );
END;
$$;
COMMENT ON FUNCTION has_permission(text) IS '权限点判定（040 单码制双通道: role_api→api_code ∪ role_menu→menu.perms；超管短路；按钮码与权限点同体系）';

-- ---------------------------------------------------------------------------
-- §4 重建 rpc_create_menu / rpc_update_menu（038 签名不变，+按钮码硬校验/软校验）
-- ---------------------------------------------------------------------------
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
    IF NOT has_permission('sys:menu:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_name IS NULL OR trim(p_menu_name) = '' THEN
        RAISE EXCEPTION 'menu_name required' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：button 必须 perms（表级 CHECK 前置友好报错）
    IF p_menu_type = 'button' AND (p_perms IS NULL OR trim(p_perms) = '') THEN
        RAISE EXCEPTION 'button menu requires perms' USING ERRCODE = '22023';
    END IF;
    -- 040 软校验：perms 应对应 iam_api.api_code（新码可先建权限点，仅警告不阻断）
    IF p_perms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_perms AND is_active) THEN
        RAISE NOTICE 'perms [%] 未对应 iam_api.api_code——建议先建权限点再配按钮（单码制对齐）', p_perms;
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
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单新增（sys:menu:create；040: button 强制 perms + api_code 软校验——单码制）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

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
DECLARE
    v_menu_type iam_menu_type;
    v_perms     text;
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
    -- 040 单码制：更新后类型为 button 必须 perms（改类型或改 perms 均按最终值校验）
    SELECT menu_type, perms INTO v_menu_type, v_perms FROM iam_menu WHERE id = p_id;
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (COALESCE(p_perms, v_perms) IS NULL OR trim(COALESCE(p_perms, v_perms)) = '') THEN
        RAISE EXCEPTION 'button menu requires perms' USING ERRCODE = '22023';
    END IF;
    IF p_perms IS NOT NULL AND NOT EXISTS (SELECT 1 FROM iam_api WHERE api_code = p_perms AND is_active) THEN
        RAISE NOTICE 'perms [%] 未对应 iam_api.api_code——建议先建权限点再配按钮（单码制对齐）', p_perms;
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
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) IS '菜单修改（sys:menu:update；040: button 强制 perms + api_code 软校验——单码制）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_check     int;
    v_btn       int;
    v_btn_nulls int;
    v_api_codes int;
    v_ch1       boolean;   -- 通道1: role_api→api_code
    v_ch2       boolean;   -- 通道2: role_menu→menu.perms
    v_deny      boolean;   -- 无权限角色拒绝
    v_deny_create boolean; -- button 无 perms 创建被拒
BEGIN
    SELECT count(*) INTO v_check FROM pg_constraint
    WHERE conname = 'iam_menu_button_perms_check';
    SELECT count(*), count(*) FILTER (WHERE perms IS NULL OR trim(perms) = '')
      INTO v_btn, v_btn_nulls FROM iam_menu WHERE menu_type = 'button';
    SELECT count(*) INTO v_api_codes FROM iam_api WHERE api_code IS NOT NULL;

    -- 双通道判定（伪 claims）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    v_ch1 := has_permission('sys:menu:create');          -- 通道1（role_api 绑定）
    v_ch2 := has_permission('sys:user:add');             -- 通道2（button perms，role_super_admin 绑全部菜单）
    PERFORM set_config('request.jwt.claims', '{"roles":["tenant_admin"]}', true);
    v_deny := NOT has_permission('sys:user:add');        -- tenant_admin 未绑该码（api 14 条 + 菜单 0 条）

    -- button 无 perms 创建被拒（超管短路 → 走到 040 硬校验 22023）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    BEGIN
        PERFORM api_v1_public.rpc_create_menu(p_menu_name => '__test_btn__', p_menu_type => 'button');
        v_deny_create := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_btn__';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_deny_create := true;
    END;

    RAISE NOTICE '040: 约束=%（期望1） 按钮=% 按钮空perms=%（期望0） api_code总数=%（期望27） 通道1=% 通道2=% 拒绝=% 按钮无码创建拒绝=%',
        v_check, v_btn, v_btn_nulls, v_api_codes, v_ch1, v_ch2, v_deny, v_deny_create;

    IF v_check <> 1 OR v_btn_nulls <> 0 OR v_api_codes <> 27
       OR v_ch1 IS NOT TRUE OR v_ch2 IS NOT TRUE OR v_deny IS NOT TRUE OR v_deny_create IS NOT TRUE THEN
        RAISE EXCEPTION '040 验证失败';
    END IF;
    RAISE NOTICE '040: 全部验证通过';
END $$;
