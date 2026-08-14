-- =============================================================================
-- 045_rpc_create_menu_with_api.sql — 合并创建 RPC（菜单+接口一次事务提交）
-- =============================================================================
-- 背景: 2026-08-09 用户拍板（资源树一体化方案；字段分析结论 ② 一致性兜底之"合并 RPC"）
--   前端"一个表单"体验：新建按钮（或菜单）时内嵌接口区，一次提交同时写 iam_menu + iam_api
-- 设计:
--   - rpc_create_menu_with_api = rpc_create_menu 全部参数 + 接口参数（p_api_path 填了才创建）
--   - 单码制: 接口 api_code 复用菜单参数 p_api_code（同一码，天然一致）
--   - 归属: 新建接口 menu_id = 新菜单 id（接口挂该节点下——按钮>接口 或 菜单>接口 均支持）
--   - 分组: p_api_group 留空默认取菜单名（与 rpc_create_api 043 同惯例）
--   - 权限门槛: sys:menu:create（创建菜单的权限即含同建接口）
--   - 事务: 单函数天然原子——任一失败整体回滚（含菜单）
-- 校验:
--   - 菜单侧: 同 rpc_create_menu（名称/类型/button api_code 必填 + 软校验 NOTICE）
--   - 接口侧: path+method 唯一、api_code 唯一（前置友好报错 22023，不依赖 UNIQUE 报错）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================




-- ---------------------------------------------------------------------------
-- 验证（smoke：超管创建测试按钮+接口 → 校验 → 清理）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_id     uuid;
    v_api_id uuid;
    v_res    json;
    v_ok     boolean;
    v_fn_ok  boolean;
BEGIN
    -- 环境自适应（17 号文档）：rpc_create_menu_with_api 已随 055 退役（D2），
    -- 函数与 iam_api 表均不存在 → 跳过行为验证
    v_fn_ok := to_regprocedure('api_v1_public.rpc_create_menu_with_api(text,uuid,text,text,text,text,text,int,boolean,text,text,text,boolean,boolean,text,boolean,text,text,text,text,text)') IS NOT NULL;
    IF NOT v_fn_ok THEN
        RAISE NOTICE '045: 菜单+接口合并创建 RPC 已退役（055 D2），行为验证跳过';
    ELSE
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);

    -- 1. 正常路径：button + api
    v_res := api_v1_public.rpc_create_menu_with_api(
        p_menu_name => '__smoke_045__', p_menu_type => 'button',
        p_api_code => 'sys:smoke:045', p_router => null,
        p_api_path => '/rpc/sys:smoke:045', p_api_method => 'POST',
        p_api_name => '045 冒烟接口');
    v_id := (v_res->>'id')::uuid;
    v_api_id := (v_res->>'api_id')::uuid;
    IF v_id IS NULL OR v_api_id IS NULL THEN
        RAISE EXCEPTION '045: smoke 创建失败';
    END IF;
    SELECT (api_code = 'sys:smoke:045') AND (menu_id = v_id) INTO v_ok
    FROM iam_api WHERE id = v_api_id;
    IF v_ok IS NOT TRUE THEN
        RAISE EXCEPTION '045: 接口归属/单码制校验失败';
    END IF;

    -- 2. 拒绝路径：重复 path+method 报 22023
    BEGIN
        PERFORM api_v1_public.rpc_create_menu_with_api(
            p_menu_name => '__smoke_045_dup__', p_menu_type => 'button',
            p_api_code => 'sys:smoke:045x',
            p_api_path => '/rpc/sys:smoke:045', p_api_method => 'POST');
        RAISE EXCEPTION '045: 重复 path+method 未被拒绝';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL; -- 预期
    END;

    -- 清理
    DELETE FROM iam_api WHERE id = v_api_id;
    DELETE FROM iam_menu WHERE id = v_id;
    RAISE NOTICE '045: 全部验证通过（合并创建+单码制+唯一性拒绝）';
    END IF;
END $$;

NOTIFY pgrst, 'reload schema';
