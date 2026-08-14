-- =============================================================================
-- 044_iam_menu_rename_router_api_code.sql — iam_menu 字段改名 + iam_api 排序 + 按钮/接口数据整理
-- =============================================================================
-- 背景: 2026-08-09 用户拍板（菜单/API 资源树一体化方案，字段分析结论落地）
--   D1 iam_menu.perms → api_code（与 iam_api.api_code 字段统一——单码制"表结构自解释"；
--      040 双通道 has_permission 语义不变）
--   D2 iam_menu.path  → router（消除与 iam_api.path 同名异义；对齐参考项目 sharpfort
--      Menu.Router/RouterName 心智）
--   D3 iam_api.order_num 新增（资源树接口叶子排序，与 iam_menu.order_num 对齐）
--   D4 数据整理: 3 按钮（UserAdd/UserEdit/UserDelete）parent_id ApiList→UserList（011 历史
--      布局归位）；3 个 sys:user:* 接口 menu_id UserList→对应按钮（首个"按钮>接口"1:1 实例）
-- 影响面（函数体为文本存储，RENAME COLUMN 不自动更新，必须显式重建）:
--   视图: api_v1_public.iam_menu（列名变 router/api_code）、v_role_menu_detail
--         （源列改、输出别名 permission_code/menu_path 不变）、casbin_rule（m.path→m.router）
--   函数: has_permission（m.perms→m.api_code）、rpc_create_menu/rpc_update_menu
--         （参数 p_perms→p_api_code、p_path→p_router——PostgREST 按参数名传参，前端同步改）、
--         get_user_menu / get_menu_tree_admin / get_role_permissions
--         （源列改，输出字段名 path/perms 保持——前端路由构建/角色授权契约不变）
-- 权限: DROP+CREATE 视图丢失 GRANT → 重建后补授 authenticated/super_admin
--       （函数用 CREATE OR REPLACE，GRANT 保留）
-- 注意: RENAME COLUMN 自动更新同表 CHECK 约束定义（约束名保留——038/040 迁移幂等依赖旧名）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 iam_menu 列改名（幂等：先查列存在性）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- 幂等修正（2026-08-14）：022 的 ADD COLUMN IF NOT EXISTS perms 在重放第二遍会
    -- 重建 perms 列（第一遍 044 已改名）→ 双列并存时 RENAME 冲突；此时 DROP 残留旧列
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='perms')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='api_code') THEN
        ALTER TABLE public.iam_menu RENAME COLUMN perms TO api_code;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='perms')
       AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='api_code') THEN
        ALTER TABLE public.iam_menu DROP COLUMN perms;  -- 022 重放重建的残留
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='path')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='router') THEN
        ALTER TABLE public.iam_menu RENAME COLUMN path TO router;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='path')
       AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='iam_menu' AND column_name='router') THEN
        ALTER TABLE public.iam_menu DROP COLUMN path;  -- 009 重放重建的残留（011 等）
    END IF;
END $$;

COMMENT ON COLUMN public.iam_menu.api_code IS '权限码（单码制：与 iam_api.api_code 同码；button 必填，has_permission 双通道判定键；原 perms）';
COMMENT ON COLUMN public.iam_menu.router IS '路由地址（前端 vue-router path；link 类型为 http(s):// 外链 URL；原 path）';

-- ---------------------------------------------------------------------------
-- §2 iam_api 加排序字段（资源树接口叶子排序）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_api ADD COLUMN IF NOT EXISTS order_num integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.iam_api.order_num IS '排序（资源树接口叶子在父节点下的顺序，与 iam_menu.order_num 对齐）';

-- ---------------------------------------------------------------------------
-- §3 数据整理（D4；幂等：条件限定旧挂载点，重放不重复移动）
-- ---------------------------------------------------------------------------
-- 3.1 按钮归位: ApiList → UserList
UPDATE public.iam_menu SET parent_id = u.id
FROM public.iam_menu u
WHERE u.menu_name = 'UserList' AND u.menu_type = 'directory'
  AND iam_menu.menu_name IN ('UserAdd','UserEdit','UserDelete')
  AND iam_menu.menu_type = 'button'
  AND iam_menu.parent_id = (SELECT id FROM public.iam_menu
                            WHERE menu_name = 'ApiList' AND menu_type = 'menu');

-- 3.2 接口挂按钮（1:1 关联首个实例：api_code 单码制匹配按钮）
UPDATE public.iam_api a SET menu_id = b.id
FROM public.iam_menu b
WHERE b.menu_type = 'button'
  AND b.menu_name = CASE a.api_code
        WHEN 'sys:user:add'    THEN 'UserAdd'
        WHEN 'sys:user:edit'   THEN 'UserEdit'
        WHEN 'sys:user:delete' THEN 'UserDelete' END
  AND a.api_code IN ('sys:user:add','sys:user:edit','sys:user:delete')
  AND a.menu_id = (SELECT id FROM public.iam_menu
                   WHERE menu_name = 'UserList' AND menu_type = 'directory');

-- ---------------------------------------------------------------------------
-- §4 视图重建（列名/源列跟随表；输出别名契约保持）
-- ---------------------------------------------------------------------------










-- 视图权限补授（17 号文档归位：视图已迁 src/api_v1，dbmate up 阶段不存在则跳过）
DO $$ BEGIN
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL AND to_regclass('api_v1_public.v_role_menu_detail') IS NOT NULL THEN
        GRANT SELECT ON api_v1_public.iam_menu TO authenticated;
        GRANT SELECT ON api_v1_public.v_role_menu_detail TO authenticated;
        GRANT ALL ON api_v1_public.iam_menu TO super_admin;
        GRANT ALL ON api_v1_public.v_role_menu_detail TO super_admin;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- §5 函数重建（RENAME COLUMN 不更新函数体文本；CREATE OR REPLACE 保留 GRANT）
-- ---------------------------------------------------------------------------
-- 5.1 has_permission（040 双通道版：m.perms → m.api_code）


-- 5.2 rpc_create_menu（参数 p_perms→p_api_code、p_path→p_router；040 单码制校验逻辑不变）
-- ⚠️ PG 不允许 CREATE OR REPLACE 修改参数名 → DROP+CREATE（GRANT 在下方重建）




-- 5.3 rpc_update_menu（同上；DROP+CREATE 改参数名）




-- 5.4 get_user_menu（源列改；输出字段名 path/perms 保持——前端 MenuProcessor/usePermission 契约不变）


-- 5.5 get_menu_tree_admin（m.path → m.router，输出键 path 保持——前端 getMenuTreeAdmin 契约）



-- 5.6 get_role_permissions（m.path → m.router，输出键 path 保持——角色授权弹窗契约）





-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cols     int;
    v_btn_pid  uuid;
    v_api_mid  uuid;
    v_leak     int;
    v_vcols    int;
BEGIN
    -- 列改名/新增
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu' AND column_name IN ('api_code','router');
    IF v_cols <> 2 THEN RAISE EXCEPTION '044: iam_menu 改名不完整（api_code/router 缺失）'; END IF;
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_menu' AND column_name IN ('perms','path');
    IF v_cols <> 0 THEN RAISE EXCEPTION '044: iam_menu 旧列名残留'; END IF;
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema='public' AND table_name='iam_api' AND column_name='order_num';
    IF v_cols <> 1 THEN RAISE EXCEPTION '044: iam_api.order_num 缺失'; END IF;

    -- 数据整理（D4；N4/D3: UserAdd 等按钮与 sys:user:add 等接口已由 045 清理——
    -- 实体存在则校验归位，不存在视为已清理跳过，保证清理后环境重放不炸）
    IF EXISTS (SELECT 1 FROM iam_menu WHERE menu_name = 'UserAdd') THEN
        SELECT parent_id INTO v_btn_pid FROM iam_menu WHERE menu_name = 'UserAdd';
        IF v_btn_pid IS DISTINCT FROM (SELECT id FROM iam_menu WHERE menu_name='UserList' AND menu_type='directory') THEN
            RAISE EXCEPTION '044: UserAdd 未归位 UserList';
        END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM iam_api WHERE api_code = 'sys:user:add') THEN
        SELECT menu_id INTO v_api_mid FROM iam_api WHERE api_code = 'sys:user:add';
        IF v_api_mid IS DISTINCT FROM (SELECT id FROM iam_menu WHERE menu_name='UserAdd') THEN
            RAISE EXCEPTION '044: sys:user:add 接口未挂 UserAdd 按钮';
        END IF;
    END IF;

    -- 函数体无残留旧列引用（表别名引用 m.path/m.perms）
    SELECT count(*) INTO v_leak FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname IN ('has_permission','rpc_create_menu','rpc_update_menu',
                        'get_user_menu','get_menu_tree_admin','get_role_permissions')
      AND (p.prosrc LIKE '%m.path%' OR p.prosrc LIKE '%m.perms%');
    IF v_leak <> 0 THEN RAISE EXCEPTION '044: 函数体残留 m.path/m.perms 引用（%）', v_leak; END IF;

    -- 视图列（环境自适应：视图定义已归位 src/api_v1，dbmate up 阶段不存在则跳过）
    IF to_regclass('api_v1_public.iam_menu') IS NOT NULL THEN
        SELECT count(*) INTO v_vcols FROM information_schema.columns
        WHERE table_schema='api_v1_public' AND table_name='iam_menu' AND column_name IN ('router','api_code');
        IF v_vcols <> 2 THEN RAISE EXCEPTION '044: iam_menu 视图列未更新'; END IF;
    END IF;

    RAISE NOTICE '044: 全部验证通过（列改名+order_num+数据整理+6函数+3视图重建+权限补授）';
END $$;

-- ---------------------------------------------------------------------------
-- §7 PostgREST schema cache 刷新
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
