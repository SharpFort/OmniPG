-- =============================================================================
-- 055_iam_menu_permission_unify.sql — 菜单权限单表化（SharpFort 模型，D1-D12）
-- =============================================================================
-- 背景: 2026-08-12 用户拍板（docs/开发实施方案/16-菜单权限单表化-SharpFort模型-决策与实施清单.md v1.1）
--   D1 删除 iam_api 表：端点信息并入 iam_menu（api_url/api_method 内嵌按钮行）
--   D2 删除 iam_role_api 表：角色授权收敛为 iam_role_menu 单表（授权树=菜单树勾选）
--   D3 has_permission 单通道：role_menu → menu.api_code（超管短路保留）
--   D4 一码多端点 = 多行同 api_code 的 button 行（api_code 非唯一索引）
--   D5 iam_menu +is_affix（借鉴 Admin.NET IsAffix，标签页固定）
--   D6 api_url/api_method 成对 CHECK + api_method 值域 CHECK（含 '*'）+ 部分唯一索引
--   D8 button 行导航字段置空 CHECK（router/component 必须 NULL，借鉴 Admin.NET CheckMenuParam）
--   D9 遗留数据彻底重构：无码行/死端点行直接清除不转换；有码行按 T1 规则转换；
--      非 button 行 api_code 收敛置空（码只归 button 行——Admin.NET 非 Btn 行 Permission 强制 NULL 同款语义）
--   D10 删除 041 子树授权 RPC（rpc_grant_menu_subtree_apis / rpc_revoke_menu_subtree_apis）
--   D11 权限码命名空间统一 sys: → public:（v1.2 用户拍板：权限码前缀 = 权限域命名空间，
--       与"public schema 整体即 admin 域"对齐；业务域预留 content:/ugc:；旧迁移文件函数体
--       门槛码已同步改为 public:（023-046），数据 seed 保持历史 sys: 由本迁移 §4.1.5 统一收敛，
--       幂等——重放时旧迁移重建旧码行 → 再次 UPDATE）
--   D12 占位路径映射真实端点（v1.2 用户拍板：024 的 /rpc/sys:* 人造占位路径不搬入 api_url；
--       按码→真实端点映射表（_ep_map，26 端点对）回填；sys:api:*/sys:role-api:bind 随 RPC
--       删除不迁移；dict:* 一码多端点首例（type+data 两个函数 → 同码两行，D4 落地）
-- 执行顺序（v1.1 T2 显式化）:
--   §1 DROP 依赖视图/函数/触发器 → §2 iam_menu 加列 → §3 新约束/索引 →
--   §4 数据迁移（T1 规则 + D9 清除）→ §5 DROP iam_role_api → §6 DROP iam_api →
--   §7 重建 has_permission/casbin_rule/get_role_permissions/rpc_create_menu/rpc_update_menu →
--   §8 权限点清理核对 → §9 GRANT 说明 → §10 验证 DO 块
-- 源文件同批（apply-src 顺序 src→api_v1→init→migrations；055 删表后全链重放
--   不得再有任何源文件引用 iam_api/iam_role_api，否则 42P01 全链失败）:
--   - git rm: db/api_v1/public/views/iam_api.sql、iam_role_api.sql、v_role_api_detail.sql
--   - 改: db/src/public/views/casbin_rule.sql（API 段 menu 口径）
--   - 改: db/api_v1/public/views/v_system_stats.sql（total_apis 口径）
--   - 改: db/api_v1/public/rpc/rpc_get_role_permissions.sql（apis 段菜单口径）
--   - 改: db/api_v1/public/privileges/grant_all.sql（移除 iam_api/iam_role_api/v_role_api_detail GRANT）
-- 幂等说明: 全文件幂等重放——009 等旧迁移会重建 iam_api/iam_role_api（seed 数据），
--   055 的转换/删除语句基于 EXISTS 判定与 ON CONFLICT，重放不产生重复行；
--   验证链 verify-055.js 覆盖幂等重放两遍（P1 T6）。
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 DROP 依赖对象（055 前存在、055 后不存在的对象；幂等）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_public.iam_api CASCADE;
DROP VIEW IF EXISTS api_v1_public.iam_role_api CASCADE;
DROP VIEW IF EXISTS api_v1_public.v_role_api_detail CASCADE;
                 -- §7 重建（双段 menu 口径）

-- 函数（024/027 后实际 schema = api_v1_public；DROP 带签名防重载歧义）
   -- 044 时代旧签名兜底
   -- §7 重建
DROP FUNCTION IF EXISTS api_v1_public.rpc_set_role_apis(text, text[]);          -- 024；D2
DROP FUNCTION IF EXISTS api_v1_public.rpc_grant_menu_subtree_apis(text, uuid);  -- 041；D10
DROP FUNCTION IF EXISTS api_v1_public.rpc_revoke_menu_subtree_apis(text, uuid); -- 041；D10
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_api(text, text, text, text, text, boolean, uuid, text);          -- 043
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_api(uuid, text, text, text, text, text, boolean, uuid, text);    -- 043
DROP FUNCTION IF EXISTS api_v1_public.rpc_delete_api(uuid);                                                     -- 043
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu_with_api(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, text, text, text); -- 045
DROP FUNCTION IF EXISTS api_v1_public.rpc_set_menu_apis(uuid, uuid[]);           -- 046

-- 触发器（028 曾改名 trg_audit_sys_role_api → trg_audit_role_api，两个旧名都清）
DROP TRIGGER IF EXISTS trg_audit_sys_role_api ON iam_role_api;
DROP TRIGGER IF EXISTS trg_audit_role_api ON iam_role_api;

-- ---------------------------------------------------------------------------
-- §2 iam_menu 加列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.iam_menu
    ADD COLUMN IF NOT EXISTS api_url    varchar(255),
    ADD COLUMN IF NOT EXISTS api_method varchar(10),
    ADD COLUMN IF NOT EXISTS is_affix   boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.iam_menu.api_url IS 'API 端点路径（原 iam_api.path，055 单表化 D1；仅 button 行使用；SharpFort ApiUrl 借鉴；约定以 / 开头不含 {}，RPC 层软校验 P2）';
COMMENT ON COLUMN public.iam_menu.api_method IS 'API 端点方法（原 iam_api.method，055 单表化 D1；api_url 非空时必填，值域 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS/*；SharpFort ApiMethod 借鉴）';
COMMENT ON COLUMN public.iam_menu.is_affix IS '是否固定标签页（Admin.NET IsAffix 借鉴；多页签前端布局使用，默认 false）';

-- ---------------------------------------------------------------------------
-- §2.5 button 行导航字段清理（D8 前置：033 回填的 button 行可能带历史 router/component，
--    必须先清空再建 CHECK，否则存量数据违例导致约束创建失败）
-- ---------------------------------------------------------------------------
UPDATE public.iam_menu
SET router = NULL, component = NULL, updated_at = now()
WHERE menu_type = 'button' AND (router IS NOT NULL OR component IS NOT NULL);

-- ---------------------------------------------------------------------------
-- §3 新约束/索引（幂等 DO 块）
--    保留既有 3 CHECK: iam_menu_link_path_check / iam_menu_is_link_path_check /
--                      iam_menu_button_perms_check（038/040，RENAME 后约束名不变）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- D6: api_url/api_method 成对
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_api_pair_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_api_pair_check
        CHECK (api_url IS NULL OR api_method IS NOT NULL);
    END IF;
    -- D6: api_method 值域（'*' 保留通配语义，与 009 iam_api.method DEFAULT '*' 一脉相承）
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_api_method_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_api_method_check
        CHECK (api_method IS NULL OR api_method IN
               ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*'));
    END IF;
    -- D8: button 行导航字段置空（"按钮行不污染 UI"表级化；Admin.NET CheckMenuParam 同款语义）
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'iam_menu_button_nav_null_check') THEN
        ALTER TABLE public.iam_menu ADD CONSTRAINT iam_menu_button_nav_null_check
        CHECK (menu_type <> 'button' OR (router IS NULL AND component IS NULL));
    END IF;
END $$;

-- D6: 端点唯一（补齐原 iam_api UNIQUE(path, method) 表级保证；部分索引）
DROP INDEX IF EXISTS idx_iam_menu_api_url_method;
CREATE UNIQUE INDEX idx_iam_menu_api_url_method ON public.iam_menu(api_url, api_method)
    WHERE api_url IS NOT NULL;

-- D4: api_code 非唯一索引（一码多端点；权限验证查询路径——SharpFort PermissionCode 索引同款）
DROP INDEX IF EXISTS idx_iam_menu_api_code;
CREATE INDEX idx_iam_menu_api_code ON public.iam_menu(api_code);

-- ---------------------------------------------------------------------------
-- §4 数据迁移（T1 规则 + D9 清除；全部幂等）
-- ---------------------------------------------------------------------------

-- 4.1 权限点删除（D9 处置：sys:api:create/update/delete、sys:role-api:bind 随
--     043/024 RPC 删除，权限点本身不转换不保留；iam_role_api 绑定 FK CASCADE 连带删）
DELETE FROM public.iam_api
WHERE api_code IN ('sys:api:create', 'sys:api:update', 'sys:api:delete', 'sys:role-api:bind');

-- 4.1.5 权限码命名空间统一（D11：sys: → public:；旧迁移 seed 保持历史码，此处统一收敛；
--        幂等——重放时 024 等重建旧码行 → 再次 UPDATE 收敛；substring FROM 5 去掉 'sys:' 四字符）
UPDATE public.iam_api SET api_code = 'public:' || substring(api_code FROM 5)
WHERE api_code LIKE 'sys:%';
UPDATE public.iam_menu SET api_code = 'public:' || substring(api_code FROM 5)
WHERE api_code LIKE 'sys:%';

-- ---------------------------------------------------------------------------
-- §4.1.6 D12 真实端点映射表（临时表，本迁移会话内使用；26 端点对）
--   sys:api:*/sys:role-api:bind 已由 4.1 删除，不入表；dict:* 一码两行（D4 一码多端点）
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE IF NOT EXISTS _ep_map(api_code text, api_url text, api_method text);
TRUNCATE _ep_map;
INSERT INTO _ep_map VALUES
    ('public:dept:create',         '/rpc/rpc_create_department',     'POST'),
    ('public:dept:update',         '/rpc/rpc_update_department',     'POST'),
    ('public:dept:delete',         '/rpc/rpc_delete_department',     'POST'),
    ('public:position:list',       '/rpc/rpc_get_position_tree',     'POST'),
    ('public:position:create',     '/rpc/rpc_create_position',       'POST'),
    ('public:position:update',     '/rpc/rpc_update_position',       'POST'),
    ('public:position:delete',     '/rpc/rpc_delete_position',       'POST'),
    ('public:position:assign',     '/rpc/rpc_assign_user_positions', 'POST'),
    ('public:dict:create',         '/rpc/rpc_create_dict_type',      'POST'),
    ('public:dict:create',         '/rpc/rpc_create_dict_data',      'POST'),
    ('public:dict:update',         '/rpc/rpc_update_dict_type',      'POST'),
    ('public:dict:update',         '/rpc/rpc_update_dict_data',      'POST'),
    ('public:dict:delete',         '/rpc/rpc_delete_dict_type',      'POST'),
    ('public:dict:delete',         '/rpc/rpc_delete_dict_data',      'POST'),
    ('public:menu:create',         '/rpc/rpc_create_menu',           'POST'),
    ('public:menu:update',         '/rpc/rpc_update_menu',           'POST'),
    ('public:menu:delete',         '/rpc/rpc_delete_menu',           'POST'),
    ('public:role-menu:bind',      '/rpc/rpc_set_role_menus',        'POST'),
    ('public:profile:update',      '/rpc/rpc_update_user_profile',   'POST'),
    ('public:tenant:list',         '/rpc/rpc_list_tenants',          'POST'),
    ('public:tenant-member:list',  '/rpc/rpc_list_tenant_members',   'POST'),
    ('public:config:write',        '/rpc/update_config',             'POST'),
    ('public:import',              '/rpc/import_csv',                'POST'),
    ('public:login-log:list',      '/rpc/rpc_search_login_logs',     'POST'),
    ('public:user:list',           '/rpc/search_users',              'POST'),
    ('public:data-scope:bind',     '/rpc/rpc_set_role_data_scope',   'POST');

-- ---------------------------------------------------------------------------
-- 4.2 有码行回填（D12：按映射表回填真实端点；同码多 button 行仅回填 id 最小行；
--     一码多端点（dict:*）首端点回填现有行，其余端点走 4.3 新建——每 button 行一个端点）
WITH ranked AS (
    SELECT ep.api_code, ep.api_url, ep.api_method,
           row_number() OVER (PARTITION BY ep.api_code ORDER BY ep.api_url) AS rn
    FROM _ep_map ep
)
UPDATE public.iam_menu m
SET api_url = r.api_url, api_method = r.api_method, updated_at = now()
FROM ranked r
WHERE r.rn = 1
  AND m.menu_type = 'button'
  AND m.api_code = r.api_code
  AND m.api_url IS NULL
  AND m.id = (SELECT m2.id FROM public.iam_menu m2
              WHERE m2.menu_type = 'button' AND m2.api_code = r.api_code AND m2.api_url IS NULL
              ORDER BY m2.id LIMIT 1);

-- 4.3 有码行新建 button 行（T1 规则 2：无同码 button 行 → 按原 menu_id 归属新建；
--     menu_id 为 NULL 的挂 System 根目录；一码一行逐行映射，不合并）
INSERT INTO public.iam_menu
    (parent_id, menu_name, menu_type, api_code, api_url, api_method,
     remark, order_num, is_active, created_by, created_at, updated_at)
SELECT
    COALESCE(a.menu_id, sys_root.id),
    a.name, 'button'::iam_menu_type, ep.api_code, ep.api_url, ep.api_method,
    a.description, a.order_num, a.is_active, a.created_by, now(), now()
FROM _ep_map ep
JOIN public.iam_api a ON a.api_code = ep.api_code
LEFT JOIN public.iam_menu sys_root
       ON sys_root.menu_name = 'System' AND sys_root.parent_id IS NULL
WHERE NOT EXISTS (SELECT 1 FROM public.iam_menu m
                  WHERE m.menu_type = 'button'
                    AND m.api_code = ep.api_code
                    AND m.api_url = ep.api_url
                    AND m.api_method = ep.api_method)
ON CONFLICT (api_url, api_method) WHERE api_url IS NOT NULL DO NOTHING;  -- 幂等兜底（2026-08-14）

-- 4.4 非 button 行 api_code 收敛（码只归 button 行；先复制绑定再清空）
--     4.4.1 绑定到"带码非 button 行"（如 040 UserList 目录行）的 role_menu → 复制到同码 button 行
INSERT INTO public.iam_role_menu (role_code, menu_id, created_by)
SELECT DISTINCT rm.role_code, b.id, rm.created_by
FROM public.iam_role_menu rm
JOIN public.iam_menu m ON m.id = rm.menu_id
JOIN public.iam_menu b ON b.menu_type = 'button' AND b.api_code = m.api_code
WHERE m.menu_type <> 'button' AND m.api_code IS NOT NULL
ON CONFLICT (role_code, menu_id) DO NOTHING;
--     4.4.2 清空非 button 行 api_code（Admin.NET 非 Btn 行 Permission 强制 NULL 同款语义）
UPDATE public.iam_menu
SET api_code = NULL, updated_at = now()
WHERE menu_type <> 'button' AND api_code IS NOT NULL;

-- 4.5 授权转换（T1 规则 4：iam_role_api 有码行绑定 → iam_role_menu 对应 button 行；
--     无码行绑定随 4.6 行删除，超管短路兜底）
INSERT INTO public.iam_role_menu (role_code, menu_id, created_by)
SELECT DISTINCT ra.role_code, b.id, ra.created_by
FROM public.iam_role_api ra
JOIN public.iam_api a ON a.id = ra.api_id
JOIN public.iam_menu b ON b.menu_type = 'button' AND b.api_code = a.api_code
WHERE a.api_code IS NOT NULL
  AND a.api_code NOT IN ('public:api:create', 'public:api:update', 'public:api:delete', 'public:role-api:bind')
ON CONFLICT (role_code, menu_id) DO NOTHING;

-- 4.6 无码行/死端点行清除（D9：不转换、不赋码；ALIVE 且无码的行同样清除——
--     055 后由前端菜单管理按需重建；role_api 绑定 FK CASCADE 连带删）
DELETE FROM public.iam_api WHERE api_code IS NULL;

-- 4.7 转换完整性断言（DROP 前）
--   4.7.1 数据驱动硬断言：iam_api 现存有码行必须有对应 button 行（缺失即失败）
--   4.7.2 映射表覆盖核对（NOTICE 不阻断：存量库缺码时映射端点 <26，由前端菜单管理补齐）
DO $$
DECLARE
    v_missing   int;
    v_map_miss  int;
    v_conv_btn  int;
    v_conv_bind int;
BEGIN
    SELECT count(*) INTO v_missing
    FROM public.iam_api a
    WHERE a.api_code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.iam_menu m
                      WHERE m.menu_type = 'button' AND m.api_code = a.api_code);
    IF v_missing <> 0 THEN
        RAISE EXCEPTION '055: 有码行转换缺失 % 行（api_code 无对应 button 行）', v_missing;
    END IF;
    SELECT count(*) INTO v_map_miss
    FROM _ep_map ep
    WHERE NOT EXISTS (SELECT 1 FROM public.iam_menu m
                      WHERE m.menu_type = 'button'
                        AND m.api_code = ep.api_code
                        AND m.api_url = ep.api_url
                        AND m.api_method = ep.api_method);
    SELECT count(*) INTO v_conv_btn FROM public.iam_menu
    WHERE menu_type = 'button' AND api_url IS NOT NULL;
    SELECT count(*) INTO v_conv_bind FROM public.iam_role_menu rm
    JOIN public.iam_menu m ON m.id = rm.menu_id
    WHERE m.menu_type = 'button' AND m.api_url IS NOT NULL;
    RAISE NOTICE '055: 转换完成——端点按钮行=% 端点绑定=%（role_api→role_menu）；映射表覆盖=%-%缺失（存量缺码由前端菜单管理补齐）',
        v_conv_btn, v_conv_bind, 26, v_map_miss;
END $$;

-- ---------------------------------------------------------------------------
-- §5 DROP iam_role_api（授权收敛 D2；RLS 策略 role_api_read_policy / GRANT / 索引随表删）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.iam_role_api;

-- ---------------------------------------------------------------------------
-- §6 DROP iam_api（端点信息已并入 iam_menu D1；RLS 策略 api_read_policy /
--     GRANT / idx_iam_api_code / idx_iam_api_path_method / idx_iam_api_menu 随表删）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.iam_api;

-- ---------------------------------------------------------------------------
-- §7 重建函数/视图（055 单表化语义）
-- ---------------------------------------------------------------------------

-- 7.1 has_permission 单通道（D3：role_menu → menu.api_code；超管短路保留；
--     一码多行 EXISTS 语义天然正确——任一 button 行命中即 true）


-- 7.2 casbin_rule 双段重建（API 段 = role_menu→button 行 api_url/api_method；
--     菜单段 = role_menu→router/'menu' 原样保留）


-- 17 号文档归位（2026-08-14）：casbin_rule 定义/COMMENT 已迁 src/public/views/casbin_rule.sql

-- 7.3 get_role_permissions（apis 段改"角色菜单下挂接口"：role_menu → button 行 api_url 非空；
--     输出键保持 path/method/api_name——前端授权弹窗契约不变）



-- 7.4 rpc_create_menu 重建（T3：+p_api_url/p_api_method/p_is_affix；
--     D8: button 禁传 router/component；D6: 端点成对 + 值域；
--     非 button 行 api_code/router/component/api_url 强制 NULL——Admin.NET CheckMenuParam 同款）




-- 7.5 rpc_update_menu 重建（同上；改类型时按最终类型应用字段归属规则）




-- ---------------------------------------------------------------------------
-- §8 权限点清理核对（D9/验收 10）
--    sys:api:create/update/delete、sys:role-api:bind 已随 §4.1 删除（含 iam_role_api 绑定
--    与后续 DROP TABLE 连带清理）；iam_menu 中无同码行（024/043 seed 未创建按钮）。
--    has_permission 单通道后这些码在 iam_menu 中不存在 → 判定恒 false，无悬空引用。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §9 GRANT 说明
--    本迁移无新增 GRANT：DROP VIEW/TABLE 的对象授权随对象删除自动清理；
--    casbin_rule（CREATE OR REPLACE）/ get_role_permissions / rpc_create_menu /
--    rpc_update_menu（CREATE OR REPLACE）保留原授权。
--    源文件 db/api_v1/public/privileges/grant_all.sql 已同步移除 5 处 GRANT
--    （iam_api SELECT / iam_role_api SELECT / v_role_api_detail SELECT /
--     iam_api INSERT,UPDATE role_admin / iam_role_api INSERT,UPDATE role_admin）。
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §10 验证 DO 块（结构 + 约束 + 数据质量 + 行为）
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tables    int;
    v_cols      int;
    v_checks    int;
    v_idx       int;
    v_btn_nav   int;
    v_btn_code  int;
    v_pair_bad  int;
    v_dup       int;
    v_nb_code   int;
    v_sys_left  int;
    v_endpoints int;
    v_ch_super  boolean;
    v_ch_deny   boolean;
    v_role      text;
    v_code      text;
    v_ch_role   boolean;
    v_api_seg   int;
    v_menu_seg  int;
    v_fn_ok     boolean;
BEGIN
    -- 环境自适应（17 号文档）：has_permission/casbin_rule 已迁 src，
    -- dbmate up 阶段不存在则跳过行为/视图断言；结构/约束/数据断言不受影响
    v_fn_ok := to_regprocedure('has_permission(text)') IS NOT NULL;
    -- 1. 表删除断言（D1/D2）
    SELECT count(*) INTO v_tables FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name IN ('iam_api', 'iam_role_api');
    IF v_tables <> 0 THEN RAISE EXCEPTION '055: iam_api/iam_role_api 未删除（%）', v_tables; END IF;

    -- 2. 加列断言（D1/D5）
    SELECT count(*) INTO v_cols FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'iam_menu'
      AND column_name IN ('api_url', 'api_method', 'is_affix');
    IF v_cols <> 3 THEN RAISE EXCEPTION '055: iam_menu 新列缺失（%）', v_cols; END IF;

    -- 3. 约束断言（3 旧 + 2 新）
    SELECT count(*) INTO v_checks FROM pg_constraint
    WHERE conname IN ('iam_menu_link_path_check', 'iam_menu_is_link_path_check',
                      'iam_menu_button_perms_check', 'iam_menu_api_pair_check',
                      'iam_menu_api_method_check', 'iam_menu_button_nav_null_check');
    IF v_checks <> 6 THEN RAISE EXCEPTION '055: CHECK 约束不完整（期望6 实际%）', v_checks; END IF;

    -- 4. 索引断言（D4/D6）
    SELECT count(*) INTO v_idx FROM pg_indexes
    WHERE tablename = 'iam_menu'
      AND indexname IN ('idx_iam_menu_api_url_method', 'idx_iam_menu_api_code');
    IF v_idx <> 2 THEN RAISE EXCEPTION '055: 新索引缺失（%）', v_idx; END IF;

    -- 5. 数据质量断言（D8/D6/040）
    SELECT count(*) INTO v_btn_nav FROM iam_menu
    WHERE menu_type = 'button' AND (router IS NOT NULL OR component IS NOT NULL);
    IF v_btn_nav <> 0 THEN RAISE EXCEPTION '055: button 行导航字段残留（%）', v_btn_nav; END IF;

    SELECT count(*) INTO v_btn_code FROM iam_menu
    WHERE menu_type = 'button' AND (api_code IS NULL OR trim(api_code) = '');
    IF v_btn_code <> 0 THEN RAISE EXCEPTION '055: button 行 api_code 缺失（%）', v_btn_code; END IF;

    SELECT count(*) INTO v_pair_bad FROM iam_menu
    WHERE api_url IS NOT NULL AND (api_method IS NULL OR api_method NOT IN
        ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*'));
    IF v_pair_bad <> 0 THEN RAISE EXCEPTION '055: 端点成对/值域违例（%）', v_pair_bad; END IF;

    SELECT count(*) INTO v_dup FROM (
        SELECT api_url, api_method FROM iam_menu
        WHERE api_url IS NOT NULL GROUP BY 1, 2 HAVING count(*) > 1) t;
    IF v_dup <> 0 THEN RAISE EXCEPTION '055: 端点重复（%）', v_dup; END IF;

    SELECT count(*) INTO v_nb_code FROM iam_menu
    WHERE menu_type <> 'button' AND api_code IS NOT NULL;
    IF v_nb_code <> 0 THEN RAISE EXCEPTION '055: 非 button 行 api_code 残留（%）', v_nb_code; END IF;

    -- D11: 权限码命名空间断言（sys: → public: 收敛，无残留）
    SELECT count(*) INTO v_sys_left FROM iam_menu WHERE api_code LIKE 'sys:%';
    IF v_sys_left <> 0 THEN RAISE EXCEPTION '055: 权限码 sys: 前缀残留（%）', v_sys_left; END IF;

    SELECT count(*) INTO v_endpoints FROM iam_menu WHERE api_url IS NOT NULL;
    IF v_endpoints = 0 THEN RAISE EXCEPTION '055: 无转换出的端点按钮行'; END IF;

    IF v_fn_ok THEN
    -- 6. 行为断言（D3 单通道）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    v_ch_super := has_permission('public:menu:create');          -- 超管短路
    PERFORM set_config('request.jwt.claims', '{"roles":["__no_such_role__"]}', true);
    v_ch_deny  := NOT has_permission('public:menu:create');      -- 未绑角色拒绝
    IF NOT v_ch_super OR NOT v_ch_deny THEN
        RAISE EXCEPTION '055: has_permission 单通道行为异常（super=% deny=%）', v_ch_super, v_ch_deny;
    END IF;
    -- 有绑定非超管角色命中（存量库若仅有超管则跳过——011 语义租户角色待管理端绑定）
    SELECT rm.role_code, m.api_code INTO v_role, v_code
    FROM iam_role_menu rm JOIN iam_menu m ON m.id = rm.menu_id
    WHERE rm.role_code <> 'role_super_admin'
      AND m.api_code IS NOT NULL AND m.is_active
    LIMIT 1;
    IF FOUND THEN
        PERFORM set_config('request.jwt.claims',
            jsonb_build_object('roles', jsonb_build_array(v_role))::text, true);
        v_ch_role := has_permission(v_code);
        IF NOT v_ch_role THEN
            RAISE EXCEPTION '055: 单通道绑定命中失败 [%/%]', v_role, v_code;
        END IF;
    END IF;

    -- 7. casbin_rule 双段断言（7.2）
    SELECT count(*) INTO v_api_seg FROM casbin_rule WHERE v2 <> 'menu';
    SELECT count(*) INTO v_menu_seg FROM casbin_rule WHERE v2 = 'menu';
    IF v_api_seg = 0 OR v_menu_seg = 0 THEN
        RAISE EXCEPTION '055: casbin_rule 双段异常（api_seg=% menu_seg=%）', v_api_seg, v_menu_seg;
    END IF;

    RAISE NOTICE '055: 全部验证通过（表删=1 列=3 约束=6 索引=2 端点=% 双段=%/% 单通道超管=% 拒绝=%）',
        v_endpoints, v_api_seg, v_menu_seg, v_ch_super, v_ch_deny;
    END IF;
END $$;
