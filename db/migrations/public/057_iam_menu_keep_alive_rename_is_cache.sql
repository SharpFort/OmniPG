-- =============================================================================
-- 057_iam_menu_keep_alive_rename_is_cache.sql — keep_alive → is_cache 列改名
-- =============================================================================
-- 背景: 2026-08-13 用户拍板（B3）:
--   ① 语义对标 SharpFort IsCache / RuoYi is_cache（页面缓存语义）
--   ② iam_menu 布尔列命名统一——is_active/is_visible/is_link/is_iframe/is_affix
--      全部 is_ 前缀，keep_alive 是唯一例外
--   ⚠️ PG 列名用 is_cache 而非 C# 风格 IsCache：PG 未加引号标识符强制折叠小写
--      （IsCache 会变 iscache）；前端 Vue 路由 meta.keepAlive（art-page-content
--      消费）不改——Vue 生态惯例名，与 DB 字段已解耦
-- 决策:
--   列 keep_alive → is_cache（值随列保留，无数据迁移）；
--   rpc_create_menu / rpc_update_menu 参数 p_keep_alive → p_is_cache（统一 API 面）；
--   get_user_menu 输出键 keep_alive → is_cache（前端 MenuProcessor 映射同步一行）
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（is_cache）→ 057 自带重建
--   - public.get_user_menu（is_cache 输出键）→ 057 自带重建
--   - rpc_create_menu / rpc_update_menu（p_is_cache；签名类型不变 18/20 参）
-- ⚠️ RENAME 联动范围（023 教训）: RENAME COLUMN 自动更新视图/RLS 策略/触发器
--   （OID 依赖），但 PL/pgSQL 函数体是文本、不自动更新 → 必须重建 get_user_menu /
--   rpc_create_menu / rpc_update_menu，否则列改名后调用 42703
-- ⚠️ 重放收敛双分支（apply-src 全量重放架构）:
--   038 历史迁移重放会 IF NOT EXISTS 重建 keep_alive 列（NOT NULL DEFAULT true，
--   全默认值、无真实数据）→ 057 检测双列并存时 DROP 重建列（真实数据在 is_cache）；
--   首跑环境（仅 keep_alive 存在）走 RENAME 保留值
-- ⚠️ DROP 重建列前必须先 DROP VIEW（PG 列级依赖 2BP01——038/044/056 重放会
--   用含 keep_alive 的定义重建视图）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同批提交）:
--   - db/api_v1/public/views/iam_menu.sql（keep_alive → is_cache）
--   - db/src/public/functions/get_user_menu.sql（keep_alive → is_cache）
-- 历史迁移 038/040/044/045/055/056 保持原样（各自时代语义；056 前形态引用
--   keep_alive 列在重放时由 038 重建、057 收敛——幂等不变式）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 视图依赖解除（幂等；DROP 重建列前必须）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §2 列改名双分支收敛（幂等）
--     首跑：仅 keep_alive 存在 → RENAME（NOT NULL DEFAULT true 等约束随列走）
--     重放：keep_alive + is_cache 并存 → 038 重建了 keep_alive（全默认值）→ DROP
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'iam_menu'
                 AND column_name = 'keep_alive')
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'iam_menu'
                     AND column_name = 'is_cache') THEN
        -- 重放环境：keep_alive 为 038 重放重建（全默认值 true，无真实数据），删除
        ALTER TABLE public.iam_menu DROP COLUMN keep_alive;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'iam_menu'
                    AND column_name = 'keep_alive') THEN
        -- 首跑环境：改名，值随列保留
        ALTER TABLE public.iam_menu RENAME COLUMN keep_alive TO is_cache;
    END IF;
END $$;

COMMENT ON COLUMN public.iam_menu.is_cache IS '是否缓存页面（keep-alive，默认 true；057 由 keep_alive 改名——语义对标 SharpFort IsCache/RuoYi is_cache + iam_menu 布尔列 is_ 前缀命名统一）';

-- ---------------------------------------------------------------------------
-- §3 重建暴露视图（is_cache；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------

-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
        GRANT ALL ON api_v1_public.iam_menu TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §4 重建 get_user_menu（输出键 is_cache；与 src/public/functions/get_user_menu.sql 一致）
--     ⚠️ 必须自带重建：PL/pgSQL 函数体不随 RENAME 自动更新，否则调用 42703
--     ⚠️ 输出键变化 = 前端契约变化：MenuProcessor 读 menu.is_cache → meta.keepAlive
--        （Vue 侧 meta.keepAlive 本身不改）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §5 重建 rpc_create_menu（p_keep_alive → p_is_cache；签名类型不变 18 参）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §6 重建 rpc_update_menu（p_keep_alive → p_is_cache；签名类型不变 20 参）
-- ---------------------------------------------------------------------------




-- ---------------------------------------------------------------------------
-- §7 验证 DO 块（结构 + 参数名 + 行为）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_ka_col    int;
    v_ic_col    int;
    v_view_ka   int;
    v_view_ic   int;
    v_c_ka      int;
    v_c_ic      int;
    v_u_ka      int;
    v_u_ic      int;
    v_id        uuid;
    v_def_ic    boolean;
    v_set_ic    boolean;
    v_menu      json;
    v_out_ka    int;
    v_out_ic    int;
    v_fn_ok     boolean;
BEGIN
    -- 环境自适应（17 号文档：rpc_create_menu/rpc_update_menu/get_user_menu 定义已归位 src，
    -- dbmate up 阶段不存在则跳过行为断言；列/视图断言不受影响）
    v_fn_ok := to_regprocedure('api_v1_public.rpc_create_menu(text,uuid,text,text,text,text,text,int,boolean,boolean,text,text,text,text,text,text,text,text)') IS NOT NULL;
    -- 崩溃残留清理（幂等重放安全；先清审计行——target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    -- 1. 列断言（keep_alive 无、is_cache 有）
    SELECT count(*) INTO v_ka_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'keep_alive';
    SELECT count(*) INTO v_ic_col FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu' AND column_name = 'is_cache';
    IF v_ka_col <> 0 OR v_ic_col <> 1 THEN
        RAISE EXCEPTION '057: 列状态异常（keep_alive=% is_cache=%）', v_ka_col, v_ic_col;
    END IF;

    -- 2. 视图列断言（keep_alive 无、is_cache 有；环境自适应：视图已迁 src，dbmate 阶段不存在则跳过）
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
    SELECT count(*) INTO v_view_ka FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'keep_alive';
    SELECT count(*) INTO v_view_ic FROM information_schema.columns
    WHERE table_schema = 'api_v1_public' AND table_name = 'iam_menu' AND column_name = 'is_cache';
    IF v_view_ka <> 0 OR v_view_ic <> 1 THEN
        RAISE EXCEPTION '057: 视图列异常（keep_alive=% is_cache=%）', v_view_ka, v_view_ic;
    END IF;
    END IF;

    -- 3. RPC 参数名断言（p_keep_alive 无、p_is_cache 有；环境自适应：函数已迁 src，dbmate 阶段不存在则跳过）
    IF v_fn_ok THEN
    SELECT count(*) INTO v_c_ka FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_keep_alive' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_c_ic FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_create_menu'
      AND 'p_is_cache' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_ka FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_keep_alive' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    SELECT count(*) INTO v_u_ic FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api_v1_public' AND p.proname = 'rpc_update_menu'
      AND 'p_is_cache' = ANY(COALESCE(p.proargnames, ARRAY[]::name[]));
    IF v_c_ka <> 0 OR v_c_ic <> 1 OR v_u_ka <> 0 OR v_u_ic <> 1 THEN
        RAISE EXCEPTION '057: 参数名异常（c_ka=% c_ic=% u_ka=% u_ic=%）', v_c_ka, v_c_ic, v_u_ka, v_u_ic;
    END IF;
    END IF;

    -- 4. 行为：p_is_cache 默认 true / 显式 false；update 同（行为段复用 IF v_fn_ok）
    IF v_fn_ok THEN
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    SELECT (api_v1_public.rpc_create_menu(
        '__t_cache__', NULL, 'menu', NULL, '/system/cache-t', 'cache/index'
    )->>'id')::uuid INTO v_id;
    SELECT is_cache INTO v_def_ic FROM iam_menu WHERE id = v_id;
    IF v_def_ic IS NOT TRUE THEN
        RAISE EXCEPTION '057: p_is_cache 默认值异常（%）', v_def_ic;
    END IF;
    PERFORM api_v1_public.rpc_update_menu(p_id => v_id, p_is_cache => false);
    SELECT is_cache INTO v_set_ic FROM iam_menu WHERE id = v_id;
    IF v_set_ic IS NOT FALSE THEN
        RAISE EXCEPTION '057: p_is_cache=false 更新异常（%）', v_set_ic;
    END IF;
    DELETE FROM public.iam_menu WHERE id = v_id;

    -- 5. get_user_menu 输出键断言（is_cache 有、keep_alive 无）
    SELECT get_user_menu() INTO v_menu;
    SELECT count(*) INTO v_out_ka FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'keep_alive';
    SELECT count(*) INTO v_out_ic FROM json_array_elements(v_menu) e
    WHERE (e::jsonb) ? 'is_cache';
    IF v_out_ka <> 0 OR v_out_ic = 0 THEN
        RAISE EXCEPTION '057: get_user_menu 输出键异常（keep_alive=% is_cache=%）', v_out_ka, v_out_ic;
    END IF;

    -- 清理测试审计行与菜单行（先审计后菜单——审计 target_id 引用测试菜单 id）
    DELETE FROM public.audit_log WHERE target_id IN (
        SELECT id::text FROM public.iam_menu WHERE menu_name LIKE '__t_%');
    DELETE FROM public.iam_menu WHERE menu_name LIKE '__t_%';

    RAISE NOTICE '057: 全部验证通过（列/视图/参数名改名生效 行为 p_is_cache 默认true/显式false 输出键 is_cache）';
    END IF;
END $$;
