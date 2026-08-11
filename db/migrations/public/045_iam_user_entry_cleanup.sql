-- =============================================================================
-- 045_iam_user_entry_cleanup.sql — D3 用户管理入口收敛：死权限点/按钮集中清理
-- =============================================================================
-- 背景: 33 号审查文档 §9 决策 D3（2026-08-11 用户拍板）——
--   后端彻底移除用户增/删/改残留（Logto 控制台为唯一用户管理入口，前端页面自加跳转链接）。
-- 清理对象（全部为无后端支撑的死实体）:
--   ① iam_menu 按钮 UserAdd / UserEdit / UserDelete（对应 RPC create_user 015 已删）
--   ② iam_api 死端点: /sys_user POST/PATCH/DELETE（增删改）+ /rpc/kick_user POST
--      （kick_user 015 已删，D12 会话管理交 Logto）
--   ③ 死权限码: sys:user:add / sys:user:edit / sys:user:delete / sys:user:kick
-- 保留: /sys_user GET → sys:user:list（用户列表展示，rpc_search_users 支撑；040 回填）
-- 级联: iam_role_menu.menu_id / iam_role_api.api_id 均 ON DELETE CASCADE（009 §2.3/2.4）
--       → 绑定行自动清理，无需显式删除
-- 幂等: DELETE 可重复；重放顺序 003/040/044 → 045 保证最终无死码（回填先于清理）。
--       040/044 源文件已同步适配（§1 不再回填死码；验证块环境自适应）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 死按钮清理（iam_menu）
-- ---------------------------------------------------------------------------
DELETE FROM public.iam_menu
WHERE menu_type = 'button'
  AND menu_name IN ('UserAdd', 'UserEdit', 'UserDelete');

-- ---------------------------------------------------------------------------
-- §2 死端点清理（iam_api：/sys_user 增删改 + /rpc/kick_user）
-- ---------------------------------------------------------------------------
DELETE FROM public.iam_api
WHERE (path = '/sys_user' AND method IN ('POST', 'PATCH', 'DELETE'))
   OR (path = '/rpc/kick_user' AND method = 'POST');

-- ---------------------------------------------------------------------------
-- §3 死权限码清理（iam_api.api_code；行已随 §2 删除，此处兜底防历史遗留）
-- ---------------------------------------------------------------------------
DELETE FROM public.iam_api
WHERE api_code IN ('sys:user:add', 'sys:user:edit', 'sys:user:delete', 'sys:user:kick');

-- ---------------------------------------------------------------------------
-- §4 验证（死实体 0 残留；保留码 sys:user:list 存在）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_btn  int;  -- 死按钮
    v_api  int;  -- 死端点
    v_code int;  -- 死码
    v_bind int;  -- 按钮绑定残留（iam_role_menu 级联后应为 0）
    v_keep int;  -- 保留码 sys:user:list
BEGIN
    SELECT count(*) INTO v_btn FROM iam_menu
    WHERE menu_name IN ('UserAdd', 'UserEdit', 'UserDelete');
    SELECT count(*) INTO v_api FROM iam_api
    WHERE (path = '/sys_user' AND method IN ('POST', 'PATCH', 'DELETE'))
       OR (path = '/rpc/kick_user' AND method = 'POST');
    SELECT count(*) INTO v_code FROM iam_api
    WHERE api_code IN ('sys:user:add', 'sys:user:edit', 'sys:user:delete', 'sys:user:kick');
    SELECT count(*) INTO v_bind
    FROM iam_role_menu rm
    JOIN iam_menu m ON m.id = rm.menu_id
    WHERE m.menu_name IN ('UserAdd', 'UserEdit', 'UserDelete');
    SELECT count(*) INTO v_keep FROM iam_api WHERE api_code = 'sys:user:list';

    RAISE NOTICE '045: 死按钮=% 死端点=% 死码=% 按钮绑定残留=% 保留码sys:user:list=%（期望 0/0/0/0/1）',
        v_btn, v_api, v_code, v_bind, v_keep;

    IF v_btn <> 0 OR v_api <> 0 OR v_code <> 0 OR v_bind <> 0 OR v_keep <> 1 THEN
        RAISE EXCEPTION '045 清理验证失败（死实体残留或保留码缺失）';
    END IF;
    RAISE NOTICE '045: 全部验证通过';
END $$;
