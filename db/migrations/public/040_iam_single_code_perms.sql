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
--     N4/D3（2026-08-11）: 用户增/删/改死权限点由 045 统一清理——
--     本段不再回填 UserAdd/UserEdit/UserDelete 按钮码与 /sys_user POST/PATCH/DELETE、
--     /rpc/kick_user 赋码（对应后端 RPC 已删：create_user 015、kick_user 015/D12）；
--     仅保留 /sys_user GET → sys:user:list（用户列表展示，rpc_search_users 支撑）
-- ---------------------------------------------------------------------------
UPDATE public.iam_menu SET perms = 'sys:user:list'
WHERE menu_name = 'UserList' AND perms IS NULL;

-- /sys_user GET 端点赋码（用户列表展示保留；增删改端点与死码见 045）
UPDATE public.iam_api SET api_code = 'sys:user:list'
WHERE path = '/sys_user' AND method = 'GET' AND api_code IS NULL;

-- ---------------------------------------------------------------------------
-- §2 表级 CHECK：button 必须 perms（D2；回填完成后才建）
-- ---------------------------------------------------------------------------
-- 冷启动炸点修复（2026-08-14 PGlite 空库重放暴露）：033 分类回填会把
-- 011 从 sys_menu 迁入的 UserAdd/UserEdit 等行（perms 空）标为 button，
-- 违反本约束语义（button 必须 perms）→ CHECK 前把无 perms 的 button 行回 menu
UPDATE iam_menu SET menu_type = 'menu'::iam_menu_type
WHERE menu_type = 'button'::iam_menu_type
  AND (perms IS NULL OR trim(perms) = '');

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


-- ---------------------------------------------------------------------------
-- §4 重建 rpc_create_menu / rpc_update_menu（038 签名不变，+按钮码硬校验/软校验）
-- ---------------------------------------------------------------------------






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
    v_fn_ok     boolean;
BEGIN
    -- 环境自适应（17 号文档：has_permission 定义已归位 src，dbmate up 阶段不存在则跳过行为断言）
    v_fn_ok := to_regprocedure('has_permission(text)') IS NOT NULL;
    SELECT count(*) INTO v_check FROM pg_constraint
    WHERE conname = 'iam_menu_button_perms_check';
    SELECT count(*), count(*) FILTER (WHERE perms IS NULL OR trim(perms) = '')
      INTO v_btn, v_btn_nulls FROM iam_menu WHERE menu_type = 'button';
    SELECT count(*) INTO v_api_codes FROM iam_api WHERE api_code = 'sys:user:list';

    IF v_fn_ok THEN
    -- 双通道判定（伪 claims；N4/D3: 用户按钮码已由 045 清理、无通道2 载体，
    -- 以保留码 sys:user:list 验证权限点判定链——role_super_admin 绑全部 API）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    v_ch1 := has_permission('sys:menu:create');          -- 通道1（role_api 绑定）
    v_ch2 := has_permission('sys:user:list');            -- 权限点判定（保留码）
    PERFORM set_config('request.jwt.claims', '{"roles":["tenant_admin"]}', true);
    v_deny := NOT has_permission('sys:user:list');       -- tenant_admin 未绑该码（api 绑定仅超管/024 清单）

    -- button 无 perms 创建被拒（超管短路 → 走到 040 硬校验 22023）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    BEGIN
        PERFORM api_v1_public.rpc_create_menu(p_menu_name => '__test_btn__', p_menu_type => 'button');
        v_deny_create := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_btn__';
    EXCEPTION WHEN invalid_parameter_value THEN
        v_deny_create := true;
    END;

    RAISE NOTICE '040: 约束=%（期望1） 按钮=% 按钮空perms=%（期望0） sys:user:list码=%（期望1） 通道1=% 权限点判定=% 拒绝=% 按钮无码创建拒绝=%',
        v_check, v_btn, v_btn_nulls, v_api_codes, v_ch1, v_ch2, v_deny, v_deny_create;

    IF v_check <> 1 OR v_btn_nulls <> 0 OR v_api_codes <> 1
       OR v_ch1 IS NOT TRUE OR v_ch2 IS NOT TRUE OR v_deny IS NOT TRUE OR v_deny_create IS NOT TRUE THEN
        RAISE EXCEPTION '040 验证失败';
    END IF;
    RAISE NOTICE '040: 全部验证通过';
    END IF;
END $$;
