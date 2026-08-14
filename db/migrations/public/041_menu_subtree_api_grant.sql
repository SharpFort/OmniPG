-- =============================================================================
-- 041_menu_subtree_api_grant.sql — 一键授权菜单全子树 API（P0，2026-08-09 拍板）
-- =============================================================================
-- 背景: 菜单/API 管理优化结论落地（建议 3 配套；用户认可"一键授权菜单全子树 API"交互）
--   角色授权页按菜单树逐级勾选 → 授予该菜单及全部子孙菜单归属的 API 权限点
--   （iam_api.menu_id 为 join key，039 已回填 41 条）
-- 设计:
--   - rpc_grant_menu_subtree_apis: 增量授予（ON CONFLICT DO NOTHING，不动既有绑定）
--   - rpc_revoke_menu_subtree_apis: 撤销该子树归属 API（对称操作，前端取消勾选）
--   - 权限码复用 sys:role-api:bind（与 rpc_set_role_apis 同门槛）
--   - 递归 CTE 子树（含自身）；仅 is_active 菜单/API 参与
-- 源文件: 无（管理 RPC 迁移层定义惯例；api_v1/public/rpc 目录无 rpc_set_role_apis
--         → 024 起管理 CRUD RPC 均在迁移层）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 授权：授予角色「菜单及全部子孙菜单归属的 API 权限点」（增量）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §2 撤销：移除角色该子树归属的 API 权限点（对称操作，仅撤这些 API）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §3 验证（造临时菜单树 + API 归属，实测授权/撤销/过滤）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_root    uuid := uuidv7();
    v_child   uuid := uuidv7();
    v_api_ok  uuid := uuidv7();
    v_api_off uuid := uuidv7();
    v_res     json;
    v_granted int;
    v_removed int;
    v_fn_ok   boolean;
BEGIN
    -- 环境自适应（17 号文档）：rpc_grant/revoke_menu_subtree_apis 已随 055 退役
    -- （D10 单表化），函数与 iam_api/iam_role_api 表均不存在 → 跳过行为验证
    v_fn_ok := to_regprocedure('api_v1_public.rpc_grant_menu_subtree_apis(text,uuid)') IS NOT NULL;
    IF NOT v_fn_ok THEN
        RAISE NOTICE '041: 子树授权 RPC 已退役（055 D10），行为验证跳过';
    ELSE
    -- 临时树：root → child；2 个 API 归属（1 激活 1 停用）
    INSERT INTO iam_menu (id, parent_id, menu_name, menu_type) VALUES
        (v_root, NULL, '__smoke_root__', 'directory'),
        (v_child, v_root, '__smoke_child__', 'menu');
    INSERT INTO iam_api (id, path, method, name, menu_id, is_active) VALUES
        (v_api_ok,  '/__smoke__/ok',  'GET', '__smoke_ok__',  v_child, true),
        (v_api_off, '/__smoke__/off', 'GET', '__smoke_off__', v_child, false);

    -- 授权：期望 granted=1（仅激活 API；递归含子节点）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    v_res := api_v1_public.rpc_grant_menu_subtree_apis('role_super_admin', v_root);
    v_granted := (v_res->>'granted')::int;
    -- total 含既有绑定会 >1，此处仅断言 granted
    IF v_granted <> 1 OR NOT EXISTS (SELECT 1 FROM iam_role_api WHERE role_code='role_super_admin' AND api_id = v_api_ok) THEN
        RAISE EXCEPTION '041 验证失败: 授权（granted=% 期望1）', v_granted;
    END IF;
    IF EXISTS (SELECT 1 FROM iam_role_api WHERE role_code='role_super_admin' AND api_id = v_api_off) THEN
        RAISE EXCEPTION '041 验证失败: 停用 API 不应被授权';
    END IF;

    -- 幂等：再授权 granted=0（ON CONFLICT DO NOTHING）
    v_res := api_v1_public.rpc_grant_menu_subtree_apis('role_super_admin', v_root);
    IF (v_res->>'granted')::int <> 0 THEN
        RAISE EXCEPTION '041 验证失败: 重复授权非幂等（granted=% 期望0）', (v_res->>'granted')::int;
    END IF;

    -- 撤销：期望 removed=1
    v_res := api_v1_public.rpc_revoke_menu_subtree_apis('role_super_admin', v_root);
    v_removed := (v_res->>'removed')::int;
    IF v_removed <> 1 OR EXISTS (SELECT 1 FROM iam_role_api WHERE role_code='role_super_admin' AND api_id = v_api_ok) THEN
        RAISE EXCEPTION '041 验证失败: 撤销（removed=% 期望1）', v_removed;
    END IF;

    -- 清理
    DELETE FROM iam_role_api WHERE api_id IN (v_api_ok, v_api_off);
    DELETE FROM iam_api WHERE id IN (v_api_ok, v_api_off);
    DELETE FROM iam_menu WHERE id IN (v_child, v_root);

    RAISE NOTICE '041: 授权=% 幂等重授=% 撤销=% — 全部验证通过', v_granted, 0, v_removed;
    END IF;
END $$;
