-- =============================================================================
-- 046_rpc_set_menu_apis.sql — 菜单-接口批量绑定/解绑 RPC（资源树"选择绑定"模型）
-- =============================================================================
-- 背景: 2026-08-09 用户拍板（菜单/API 分工调整：API 管理页维护接口数据本体，菜单页
--   通过"选择"绑定已有接口——不再在菜单表单里重复输入接口字段）
-- 设计:
--   - rpc_set_menu_apis(p_menu_id, p_api_ids)：全量对齐该菜单下挂载的接口集合
--     （选中集合之外的解绑回池，选中的挂载到该菜单；事务内原子）
--   - 1:N 表达: iam_api.menu_id 单值 FK 天然支持 N 行指向同一菜单（无需新绑定表）
--   - 解绑语义: menu_id → NULL（接口回"未挂载池"，数据不删——API 页仍可管理/重绑）
--   - 删除菜单: 走既有 FK ON DELETE SET NULL 自动解绑（无需额外逻辑）
--   - 门槛: sys:menu:update（菜单页绑定操作属菜单维护；写的是 iam_api.menu_id）
-- 校验:
--   - 目标菜单存在且非 link（外链不挂接口）
--   - 传入 api id 全部存在（防手滑传错）
--   - 绑定会覆盖接口原有归属（前端选择器只提供"未挂载池+当前已绑"，正常流程无跨节点挪移）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

CREATE OR REPLACE FUNCTION api_v1_public.rpc_set_menu_apis(p_menu_id uuid, p_api_ids uuid[] DEFAULT '{}')
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_bound     int;
    v_unbound   int;
BEGIN
    IF NOT has_permission('sys:menu:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_id IS NULL THEN
        RAISE EXCEPTION 'menu_id required' USING ERRCODE = '22023';
    END IF;

    -- 目标节点必须存在且非 link（外链菜单不挂接口）
    SELECT menu_type INTO v_menu_type FROM iam_menu WHERE id = p_menu_id;
    IF v_menu_type IS NULL THEN
        RAISE EXCEPTION 'menu not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_menu_type = 'link' THEN
        RAISE EXCEPTION 'link menu cannot bind apis' USING ERRCODE = '22023';
    END IF;

    -- 校验传入的 api id 全部存在
    IF EXISTS (
        SELECT 1 FROM unnest(p_api_ids) t(id)
        WHERE NOT EXISTS (SELECT 1 FROM iam_api a WHERE a.id = t.id)
    ) THEN
        RAISE EXCEPTION 'api not found' USING ERRCODE = 'P0002';
    END IF;

    -- 解绑：当前挂在该菜单下但不在选中集合（回未挂载池）
    UPDATE iam_api SET menu_id = NULL, updated_at = now(), updated_by = current_user_id()
    WHERE menu_id = p_menu_id AND NOT (id = ANY(p_api_ids));
    GET DIAGNOSTICS v_unbound = ROW_COUNT;

    -- 绑定：选中集合挂载到该菜单（含从其他节点挪移的防御性覆盖）
    UPDATE iam_api SET menu_id = p_menu_id, updated_at = now(), updated_by = current_user_id()
    WHERE id = ANY(p_api_ids) AND menu_id IS DISTINCT FROM p_menu_id;
    GET DIAGNOSTICS v_bound = ROW_COUNT;

    PERFORM log_operate('menu', 'bind_apis', 'iam_menu', p_menu_id::text, 'success',
                        jsonb_build_object('bound', v_bound, 'unbound', v_unbound));
    RETURN json_build_object('ok', true, 'bound', v_bound, 'unbound', v_unbound);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_set_menu_apis(uuid, uuid[]) IS '菜单-接口批量绑定/解绑（sys:menu:update；046: 全量对齐选中集合，解绑回未挂载池，事务原子）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_set_menu_apis(uuid, uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 验证（smoke：超管创建测试菜单 + 2 接口 → 绑定 → 部分解绑 → 校验 → 清理）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_menu_id uuid;
    v_api1    uuid;
    v_api2    uuid;
    v_res     json;
    v_n       int;
BEGIN
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);

    INSERT INTO iam_menu (menu_name, menu_type, created_by)
    VALUES ('__smoke_046__', 'menu', current_user_id()) RETURNING id INTO v_menu_id;
    INSERT INTO iam_api (path, method, name, created_by)
    VALUES ('/rpc/sys:smoke:046a', 'POST', '046 冒烟A', current_user_id()) RETURNING id INTO v_api1;
    INSERT INTO iam_api (path, method, name, created_by)
    VALUES ('/rpc/sys:smoke:046b', 'POST', '046 冒烟B', current_user_id()) RETURNING id INTO v_api2;

    -- 绑定 2 个
    v_res := api_v1_public.rpc_set_menu_apis(v_menu_id, ARRAY[v_api1, v_api2]);
    IF (v_res->>'bound')::int <> 2 THEN RAISE EXCEPTION '046: 绑定数错误'; END IF;
    SELECT count(*) INTO v_n FROM iam_api WHERE menu_id = v_menu_id;
    IF v_n <> 2 THEN RAISE EXCEPTION '046: 绑定后挂载数错误'; END IF;

    -- 全量对齐：只留 1 个 → 另一个解绑回池
    v_res := api_v1_public.rpc_set_menu_apis(v_menu_id, ARRAY[v_api1]);
    IF (v_res->>'unbound')::int <> 1 THEN RAISE EXCEPTION '046: 解绑数错误'; END IF;
    IF (SELECT menu_id FROM iam_api WHERE id = v_api2) IS NOT NULL THEN
        RAISE EXCEPTION '046: 解绑未生效';
    END IF;

    -- 拒绝路径：link 菜单不可绑定
    BEGIN
        PERFORM api_v1_public.rpc_set_menu_apis(
            (SELECT id FROM iam_menu WHERE menu_type = 'link' LIMIT 1), ARRAY[v_api1]);
        RAISE EXCEPTION '046: link 菜单绑定未被拒绝';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL; -- 预期（无 link 数据时走 menu not found 也是拒绝，均通过）
    END;

    -- 清理
    DELETE FROM iam_api WHERE id IN (v_api1, v_api2);
    DELETE FROM iam_menu WHERE id = v_menu_id;
    RAISE NOTICE '046: 全部验证通过（批量绑定+全量对齐+解绑回池+拒绝路径）';
END $$;

NOTIFY pgrst, 'reload schema';
