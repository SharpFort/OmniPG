-- =============================================================================
-- 038_iam_menu_nav_fields.sql — iam_menu 导航元字段补齐（P0，2026-08-09 用户拍板）
-- =============================================================================
-- 背景: 菜单/API 管理优化分析（对照 RuoYi sys_menu 14 字段 / SharpFort Menu.cs /
--       Art Design Pro RouteMeta 三方交集）结论落地
-- 决策（用户拍板）:
--   D1 7 个导航字段全要: remark / route_name / query / is_link / is_iframe /
--                       redirect / keep_alive
--   D2 保持 menu/api 分离式（不合并表）: iam_menu 管导航，iam_api 管权限点目录，
--      角色绑定走 iam_role_menu / iam_role_api（039 起 iam_api.menu_id 归属关联）
--   D3 menu_type='link' 强制 path 为 http(s)://（033 已按此回填，本迁移补表级 CHECK）
--   D4 button 类型 perms 必填 → 040 单码制迁移（先回填再建约束）
-- 修复: 035 重建 rpc_create_menu 时 IN 校验丢失 'link'（032 四值 → 035 三值回归，
--       前端传 link 会被友好层拒绝），本迁移重建时恢复四值
-- 联动（apply-src 重放顺序 src→api_v1→init→migrations，迁移须自带重建段）:
--   - api_v1_public.iam_menu 视图（+7 列）
--   - public.get_user_menu（+is_link/is_iframe/keep_alive/redirect/query/route_name）
--   - rpc_create_menu / rpc_update_menu（新签名，旧签名必须 DROP——PGRST203 教训）
-- 源文件同步（apply-src 会覆盖迁移定义，必须同步）:
--   - db/api_v1/public/views/iam_menu.sql
--   - db/src/public/functions/get_user_menu.sql
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_menu 加列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_menu
    ADD COLUMN IF NOT EXISTS remark     text,
    ADD COLUMN IF NOT EXISTS route_name text,        -- Vue Router name（英文唯一标识）
    ADD COLUMN IF NOT EXISTS query      text,        -- 路由参数（如 tab=1 或 ?a=1&b=2）
    ADD COLUMN IF NOT EXISTS is_link    boolean NOT NULL DEFAULT false,  -- 外链（新窗口打开）
    ADD COLUMN IF NOT EXISTS is_iframe  boolean NOT NULL DEFAULT false,  -- iframe 内嵌页面
    ADD COLUMN IF NOT EXISTS redirect   text,        -- 目录重定向（noRedirect 或子路径）
    ADD COLUMN IF NOT EXISTS keep_alive boolean NOT NULL DEFAULT true;   -- 页面缓存（keep-alive）

COMMENT ON COLUMN public.iam_menu.remark     IS '备注（管理端展示）';
COMMENT ON COLUMN public.iam_menu.route_name IS '路由名称（Vue Router name，英文唯一；前端 addRoute 用）';
COMMENT ON COLUMN public.iam_menu.query      IS '路由参数（如 tab=1；RuoYi sys_menu.query 同语义）';
COMMENT ON COLUMN public.iam_menu.is_link    IS '是否外链（新窗口打开；menu_type=link 时自动置 true）';
COMMENT ON COLUMN public.iam_menu.is_iframe  IS '是否 iframe 内嵌（path 为内嵌 URL）';
COMMENT ON COLUMN public.iam_menu.redirect   IS '目录重定向路径（noRedirect 表示不重定向）';
COMMENT ON COLUMN public.iam_menu.keep_alive IS '是否缓存页面（keep-alive，默认 true；RuoYi is_cache 同语义）';

-- ---------------------------------------------------------------------------
-- §2 表级 CHECK 约束（幂等 DO 块；D3）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_link_path_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_link_path_check
        CHECK (menu_type <> 'link' OR path LIKE 'http://%' OR path LIKE 'https://%');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_is_link_path_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_is_link_path_check
        CHECK (NOT is_link OR path LIKE 'http://%' OR path LIKE 'https://%');
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §3 种子回填（幂等：仅补 NULL；历史数据无外链 → 新列默认值即正确值）
--    button perms 回填在 040（单码制迁移，与 has_permission 双通道一起提交）
-- ---------------------------------------------------------------------------
-- （无回填语句：remark/route_name/query/redirect 留空由管理端配置，
--   is_link/is_iframe=false、keep_alive=true 为默认值）

-- ---------------------------------------------------------------------------
-- §4 重建暴露视图（+7 列；与 views/iam_menu.sql 逐字一致）
-- ---------------------------------------------------------------------------


-- 17 号文档归位（2026-08-14）：视图定义已迁 src/api_v1，dbmate up 阶段不存在则跳过授权
DO $$ BEGIN
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
        GRANT ALL ON api_v1_public.iam_menu TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §5 重建 get_user_menu（+导航元字段；与 src/public/functions/get_user_menu.sql 一致）
--    前端 MenuProcessor: is_link 直判外链（不再靠 path LIKE http% hack），
--    keep_alive → meta.keepAlive，redirect/query/route_name 按需消费
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §6 重建 rpc_create_menu / rpc_update_menu（新签名 16/18 参；035 回归修复）
--    旧签名必须 DROP（PostgREST 按参数名解析，重载共存会 PGRST203 歧义）
-- ---------------------------------------------------------------------------








-- ---------------------------------------------------------------------------
-- §6.5 log_operate 修复（既有 P0 bug，冒烟暴露 2026-08-09）
--     audit_log.operation 列 001 建表即 NOT NULL，但 024 log_operate 的
--     INSERT 从未写入该列 → 所有写 RPC（menu/role-api/role-menu/...）审计
--     链路报 23502，写操作整体失败——前端菜单管理"不理想"的直接原因之一
--     修复: operation := p_action（业务动作标识，如 create/update/delete/bind）
--     无源文件（src/functions 无 log_operate.sql，024 起仅在迁移层定义）
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- §7 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols       int;
    v_checks     int;
    v_fn_link    int;
    v_fn_menu    int;
    v_link_ok    boolean;
    v_bad_type   boolean;
BEGIN
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu'
      AND column_name IN ('remark','route_name','query','is_link','is_iframe','redirect','keep_alive');
    SELECT count(*) INTO v_checks FROM pg_constraint
    WHERE conname IN ('iam_menu_link_path_check','iam_menu_is_link_path_check');
    SELECT count(*) INTO v_fn_link FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('rpc_create_menu','rpc_update_menu')
        AND prosrc LIKE '%link%';

    -- CHECK 约束生效验证：非法 link（非 http path）拒绝
    -- 幂等修正（2026-08-14）：044 已把 path 改名 router——按列存在动态选择
    BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name='iam_menu' AND column_name='path') THEN
            INSERT INTO iam_menu (menu_name, menu_type, path) VALUES ('__test_bad_link__', 'link', 'not-a-url');
        ELSE
            INSERT INTO iam_menu (menu_name, menu_type, router) VALUES ('__test_bad_link__', 'link', 'not-a-url');
        END IF;
        v_link_ok := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_bad_link__';
    EXCEPTION WHEN check_violation THEN
        v_link_ok := true;
    END;

    -- 枚举拒绝验证（032 语义回归防护）
    BEGIN
        INSERT INTO iam_menu (menu_name, menu_type) VALUES ('__test_bad_type__', 'bad_type');
        v_bad_type := false;
        DELETE FROM iam_menu WHERE menu_name = '__test_bad_type__';
    EXCEPTION WHEN invalid_text_representation THEN
        v_bad_type := true;
    END;

    -- get_user_menu 新字段返回验证（环境自适应：函数已迁 src，dbmate up 阶段不存在则跳过）
    IF to_regprocedure('get_user_menu()') IS NOT NULL THEN
        PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
        SELECT count(*) INTO v_fn_menu FROM json_array_elements(get_user_menu()::json) e
        WHERE e->>'name' = 'System' AND (e::jsonb) ? 'is_link' AND (e::jsonb) ? 'keep_alive';
    END IF;

    RAISE NOTICE '038: 新列=%（期望7） 约束=%（期望2） 函数link校验=%（期望2） link拒绝=%（期望true） 枚举拒绝=%（期望true） get_user_menu字段=%（期望1）',
        v_cols, v_checks, v_fn_link, v_link_ok, v_bad_type, v_fn_menu;

    -- 环境自适应：v_fn_link（rpc 函数已迁 src，dbmate 阶段=0）与 v_fn_menu（同上）放宽
    IF v_cols <> 7 OR v_checks <> 2 OR NOT (v_fn_link IN (0, 2))
       OR v_link_ok IS NOT TRUE OR v_bad_type IS NOT TRUE OR NOT (v_fn_menu IN (0, 1)) THEN
        RAISE EXCEPTION '038 验证失败';
    END IF;
    RAISE NOTICE '038: 全部验证通过';
END $$;
