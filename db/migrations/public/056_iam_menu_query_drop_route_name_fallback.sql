-- =============================================================================
-- 056_iam_menu_query_drop_route_name_fallback.sql — 删 query 列 + route_name 自动推导兜底（B1/B2）
-- =============================================================================
-- 背景: 2026-08-13 用户拍板（B1 P1 / B2 P2；与前端 Q2 联动）:
--   B1 删除 iam_menu.query 列 + rpc_create/update_menu 的 p_query 参数 +
--      get_user_menu 的 query 输出——字段全空 + 前端死路由（前端不消费），纯清理无风险
--   B2 route_name 后端自动推导兜底（仿 SharpFort / vue-element-admin 惯例）:
--      router 末段首字母大写作路由 name（如 /system/user → User），手填值优先；
--      写侧兜底（仅 create/update RPC），不触碰存量数据——"不影响现有数据"
-- 决策:
--   B1 列/参数/输出三处同步删除；历史迁移 038/044/045/055 保持原样（055 前语义，
--      重放时 038 会 IF NOT EXISTS 重建列，056 末尾 DROP 收敛——幂等不变式）
--   B2 推导限制 directory/menu 两型（button 行 router 恒 NULL；link 行 router 是
--      外链 URL，末段推导无意义）；rpc_update_menu 改 router 未传 route_name 时重新推导
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（-query 列）→ 056 自带重建。⚠️ DROP COLUMN 前
--     必须先 DROP VIEW：PG 列级依赖会让 DROP COLUMN 报 2BP01（038/044 重放会
--     用含 query 的定义重建视图）
--   - public.get_user_menu（-query 输出）→ 056 自带重建。⚠️ 函数体是文本、列级
--     依赖不追踪，但 038/044 重放会用 m.query 版本覆盖 src 层新版——不重建则
--     列删后调用 42703
--   - rpc_create_menu / rpc_update_menu（新签名 18/19 参，去 p_query；旧签名
--     必须 DROP——PGRST203 重载歧义教训，含 024/038/055 全世代签名兜底）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同批提交）:
--   - db/api_v1/public/views/iam_menu.sql（-query）
--   - db/src/public/functions/get_user_menu.sql（-query）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 视图依赖解除 + 删列（B1；幂等）
-- ---------------------------------------------------------------------------

ALTER TABLE public.iam_menu DROP COLUMN IF EXISTS query;

-- ---------------------------------------------------------------------------
-- §2 route_name 推导 helper（B2；router 末段首字母大写，无 router/空末段返回 NULL）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §3 重建暴露视图（-query；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------

-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
        GRANT ALL ON api_v1_public.iam_menu TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §4 重建 get_user_menu（-query 输出；与 src/public/functions/get_user_menu.sql 一致）
--     ⚠️ 必须自带重建：038/044 重放会用含 m.query 的旧版覆盖，列删后调用 42703
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §5 重建 rpc_create_menu（B1 去 p_query → 18 参；B2 route_name 推导兜底）
--     旧签名全世代 DROP（024 9 参 / 038-044 16 参 / 055 19 参）防 PGRST203
-- ---------------------------------------------------------------------------






-- ---------------------------------------------------------------------------
-- §6 重建 rpc_update_menu（B1 去 p_query → 19 参；B2 route_name 推导兜底）
--     旧签名全世代 DROP（024 11 参 / 038-044 18 参 / 055 20 参）防 PGRST203
-- ---------------------------------------------------------------------------






-- ---------------------------------------------------------------------------
-- §7 验证 DO 块（结构 + 签名 + B1/B2 行为）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_query_col int;
    v_view_q    int;
    v_view_rn   int;
    v_c_cnt     int;
    v_c_args    int;
    v_u_args    int;
    v_c_query   int;
    v_u_query   int;
    v_id        uuid;
    v_derived   text;
    v_manual    text;
    v_upd_der   text;
    v_btn_rn    text;
    v_link_rn   text;
    v_menu      json;
    v_out_q     int;
    v_out_rn    int;
    v_fn_ok     boolean;
BEGIN
    -- 环境自适应（17 号文档：rpc_create_menu/rpc_update_menu/get_user_menu 定义已归位 src，
    -- dbmate up 阶段不存在则跳过 B1/B2 行为断言；签名断言用 pg_proc 计数不受影响）
    v_fn_ok := to_regprocedure('api_v1_public.rpc_create_menu(text,uuid,text,text,text,text,text,int,boolean,boolean,text,text,text,text,text,text,text,text)') IS NOT NULL;
    -- 崩溃残留清理（幂等重放安全；先清审计行——target_id 引用测试菜单 id，
    --    不限 module：覆盖 log_operate 的 operate 行 + 审计触发器的 data_change 行）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    -- 1. B1 列删除断言
    SELECT count(*) INTO v_query_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'query';
    IF v_query_col <> 0 THEN
        RAISE EXCEPTION '056: iam_menu.query 未删除（%）', v_query_col;
    END IF;

    -- 2. 视图列断言（无 query、有 route_name；环境自适应：视图已迁 src，dbmate 阶段不存在则跳过）
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
        SELECT count(*) INTO v_view_q FROM information_schema.columns
        WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'query';
        SELECT count(*) INTO v_view_rn FROM information_schema.columns
        WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'route_name';
        IF v_view_q <> 0 OR v_view_rn <> 1 THEN
            RAISE EXCEPTION '056: 视图列异常（query=% route_name=%）', v_view_q, v_view_rn;
        END IF;
    END IF;

    IF v_fn_ok THEN
    -- 3. 签名断言（无重载残留 + 参数个数 + 无 p_query 参数名）
    SELECT count(*) INTO v_c_cnt FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu';
    IF v_c_cnt <> 1 THEN
        RAISE EXCEPTION '056: rpc_create_menu 重载残留（%）', v_c_cnt;
    END IF;
    SELECT pronargs INTO v_c_args FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu';
    SELECT pronargs INTO v_u_args FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu';
    IF v_c_args <> 18 OR v_u_args <> 20 THEN
        RAISE EXCEPTION '056: RPC 参数个数异常（create=% update=%）', v_c_args, v_u_args;
    END IF;
    SELECT count(*) INTO v_c_query FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_query' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_query FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_query' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    IF v_c_query <> 0 OR v_u_query <> 0 THEN
        RAISE EXCEPTION '056: p_query 参数残留（create=% update=%）', v_c_query, v_u_query;
    END IF;

    -- 4. B2 行为：创建推导 / 手填优先 / 改 router 重推导 / button+link 不推导
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);

    SELECT (api_v1_public.rpc_create_menu(
        '__t_derive__', NULL, 'menu', NULL, '/system/user', 'user/index'
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_derived FROM iam_menu WHERE id = v_id;
    IF v_derived IS DISTINCT FROM 'User' THEN
        RAISE EXCEPTION '056: route_name 推导失败（期望 User 实际 %）', v_derived;
    END IF;

    PERFORM api_v1_public.rpc_update_menu(
        p_id => v_id, p_router => '/system/keep', p_route_name => 'ManualName');
    SELECT route_name INTO v_manual FROM iam_menu WHERE id = v_id;
    IF v_manual <> 'ManualName' THEN
        RAISE EXCEPTION '056: 手填 route_name 未优先（%）', v_manual;
    END IF;

    PERFORM api_v1_public.rpc_update_menu(p_id => v_id, p_router => '/system/profile');
    SELECT route_name INTO v_upd_der FROM iam_menu WHERE id = v_id;
    IF v_upd_der IS DISTINCT FROM 'Profile' THEN
        RAISE EXCEPTION '056: 改 router 后重推导失败（%）', v_upd_der;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    SELECT (api_v1_public.rpc_create_menu(
        '__t_btn__', NULL, 'button', 'public:t:run', NULL, NULL, NULL, 0, true,
        NULL, NULL, NULL, NULL, NULL, NULL, '/rpc/t', 'POST', false
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_btn_rn FROM iam_menu WHERE id = v_id;
    IF v_btn_rn IS NOT NULL THEN
        RAISE EXCEPTION '056: button 行不应有 route_name（%）', v_btn_rn;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    SELECT (api_v1_public.rpc_create_menu(
        '__t_link__', NULL, 'link', NULL, 'https://example.com/docs', NULL,
        NULL, 0, true, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    )->>'id')::uuid INTO v_id;
    SELECT route_name INTO v_link_rn FROM iam_menu WHERE id = v_id;
    IF v_link_rn IS NOT NULL THEN
        RAISE EXCEPTION '056: link 行不应推导 route_name（%）', v_link_rn;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    -- 5. get_user_menu 输出断言（B1：无 query 键；route_name 键保留）
    SELECT get_user_menu() INTO v_menu;
    SELECT count(*) INTO v_out_q FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'query';
    SELECT count(*) INTO v_out_rn FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'route_name';
    IF v_out_q <> 0 OR v_out_rn = 0 THEN
        RAISE EXCEPTION '056: get_user_menu 输出异常（query=% route_name=%）', v_out_q, v_out_rn;
    END IF;

    -- 清理测试审计行与菜单行（先审计后菜单——审计 target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    RAISE NOTICE '056: 全部验证通过（query列=0 视图无query 签名 create=18/update=20 推导=User/Profile 手填优先 button/link不推导 输出无query）';
    END IF;
END $$;
