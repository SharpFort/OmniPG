-- =============================================================================
-- 055_iam_menu_permission_unify.sql — 菜单权限单表化（SharpFort 模型，D1-D10）
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
DROP VIEW IF EXISTS public.casbin_rule CASCADE;                 -- §7 重建（双段 menu 口径）

-- 函数（024/027 后实际 schema = api_v1_public；DROP 带签名防重载歧义）
DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(uuid);   -- 044 时代旧签名兜底
DROP FUNCTION IF EXISTS api_v1_public.get_role_permissions(text);   -- §7 重建
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

-- 4.2 有码行回填（T1 规则 1：同 api_code 已有 button 行 → 回填 api_url/api_method；
--     同码多 button 行时仅回填 id 最小行——每 button 行一个端点，其余行留空待管理端配置）
UPDATE public.iam_menu m
SET api_url = a.path, api_method = a.method, updated_at = now()
FROM public.iam_api a
WHERE a.api_code IS NOT NULL
  AND a.api_code NOT IN ('sys:api:create', 'sys:api:update', 'sys:api:delete', 'sys:role-api:bind')
  AND m.menu_type = 'button'
  AND m.api_code = a.api_code
  AND m.api_url IS NULL
  AND m.id = (SELECT m2.id FROM public.iam_menu m2
              WHERE m2.menu_type = 'button' AND m2.api_code = a.api_code
              ORDER BY m2.id LIMIT 1);

-- 4.3 有码行新建 button 行（T1 规则 2：无同码 button 行 → 按原 menu_id 归属新建；
--     menu_id 为 NULL 的挂 System 根目录；一码一行逐行映射，不合并）
INSERT INTO public.iam_menu
    (parent_id, menu_name, menu_type, api_code, api_url, api_method,
     remark, order_num, is_active, created_by, created_at, updated_at)
SELECT
    COALESCE(a.menu_id, sys_root.id),
    a.name, 'button'::iam_menu_type, a.api_code, a.path, a.method,
    a.description, a.order_num, a.is_active, a.created_by, now(), now()
FROM public.iam_api a
LEFT JOIN public.iam_menu sys_root
       ON sys_root.menu_name = 'System' AND sys_root.parent_id IS NULL
WHERE a.api_code IS NOT NULL
  AND a.api_code NOT IN ('sys:api:create', 'sys:api:update', 'sys:api:delete', 'sys:role-api:bind')
  AND NOT EXISTS (SELECT 1 FROM public.iam_menu m
                  WHERE m.menu_type = 'button' AND m.api_code = a.api_code);

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
  AND a.api_code NOT IN ('sys:api:create', 'sys:api:update', 'sys:api:delete', 'sys:role-api:bind')
ON CONFLICT (role_code, menu_id) DO NOTHING;

-- 4.6 无码行/死端点行清除（D9：不转换、不赋码；ALIVE 且无码的行同样清除——
--     055 后由前端菜单管理按需重建；role_api 绑定 FK CASCADE 连带删）
DELETE FROM public.iam_api WHERE api_code IS NULL;

-- 4.7 转换完整性断言（DROP 前：有码行必须有对应 button 行端点，缺失即失败）
DO $$
DECLARE
    v_missing   int;
    v_conv_btn  int;
    v_conv_bind int;
BEGIN
    SELECT count(*) INTO v_missing
    FROM public.iam_api a
    WHERE a.api_code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.iam_menu m
                      WHERE m.menu_type = 'button'
                        AND m.api_code = a.api_code
                        AND m.api_url = a.path
                        AND m.api_method = a.method);
    IF v_missing <> 0 THEN
        RAISE EXCEPTION '055: 有码行转换缺失 % 行（api_code 无对应 button 行端点）', v_missing;
    END IF;
    SELECT count(*) INTO v_conv_btn FROM public.iam_menu
    WHERE menu_type = 'button' AND api_url IS NOT NULL;
    SELECT count(*) INTO v_conv_bind FROM public.iam_role_menu rm
    JOIN public.iam_menu m ON m.id = rm.menu_id
    WHERE m.menu_type = 'button' AND m.api_url IS NOT NULL;
    RAISE NOTICE '055: 转换完成——端点按钮行=% 端点绑定=%（role_api→role_menu）', v_conv_btn, v_conv_bind;
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
CREATE OR REPLACE FUNCTION has_permission(p_code text) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles text[];
BEGIN
    IF p_code IS NULL OR p_code = '' THEN
        RETURN false;
    END IF;
    -- 超管短路（RLS 例外同款语义）
    IF is_super_admin() THEN
        RETURN true;
    END IF;
    -- 从 JWT claims 提取角色（零查询原则：角色在 claims，绑定查小表）
    SELECT ARRAY(SELECT jsonb_array_elements_text(
                    current_setting('request.jwt.claims', true)::jsonb->'roles'))
      INTO v_roles;
    IF v_roles IS NULL OR cardinality(v_roles) = 0 THEN
        RETURN false;
    END IF;
    -- 单通道（055 D3）：权限点 = button 行 api_code（非 button 行 api_code 已收敛置空）
    RETURN EXISTS (
        SELECT 1
        FROM iam_role_menu rm
        JOIN iam_menu m ON m.id = rm.menu_id
        WHERE rm.role_code = ANY(v_roles)
          AND m.api_code = p_code
          AND m.is_active
    );
END;
$$;
COMMENT ON FUNCTION has_permission(text) IS '权限点判定（055 单通道 D3: role_menu→menu.api_code；超管短路；一码多端点 EXISTS 语义）';

-- 7.2 casbin_rule 双段重建（API 段 = role_menu→button 行 api_url/api_method；
--     菜单段 = role_menu→router/'menu' 原样保留）
DROP VIEW IF EXISTS public.casbin_rule CASCADE;
CREATE VIEW casbin_rule AS
-- API 段（055 单表化：端点随 button 行）
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    rm.role_code::varchar AS v0,
    m.api_url::varchar AS v1,
    m.api_method::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active AND m.api_url IS NOT NULL
UNION ALL
-- 菜单段（原样保留：role_menu → router/'menu'）
SELECT
    NULL::integer AS id,
    'p'::varchar AS ptype,
    rm.role_code::varchar AS v0,
    m.router::varchar AS v1,
    'menu'::varchar AS v2,
    NULL::varchar AS v3,
    NULL::varchar AS v4,
    NULL::varchar AS v5
FROM iam_role_menu rm
JOIN iam_menu m ON rm.menu_id = m.id
WHERE m.is_active;
COMMENT ON VIEW casbin_rule IS 'Casbin 策略运行视图（055 双段）：API 段 = role_menu→button 行端点（v1=api_url, v2=api_method）+ 菜单段 = role_menu→router（v2=menu）原样保留';
COMMENT ON COLUMN casbin_rule.v0 IS '策略主体：角色代码（role_code）';
COMMENT ON COLUMN casbin_rule.v1 IS '策略对象：API 路径 / 菜单路径';
COMMENT ON COLUMN casbin_rule.v2 IS '策略动作：HTTP 方法 / menu';

-- 7.3 get_role_permissions（apis 段改"角色菜单下挂接口"：role_menu → button 行 api_url 非空；
--     输出键保持 path/method/api_name——前端授权弹窗契约不变）
CREATE OR REPLACE FUNCTION api_v1_public.get_role_permissions(p_role_code text)
RETURNS json
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_role RECORD;
    v_apis json;
    v_menus json;
BEGIN
    SELECT id, name AS role_name, role_code, type, is_default INTO v_role
    FROM role WHERE role_code = p_role_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;

    -- 055 单表化：API 授权 = 角色绑定按钮行中带端点的行
    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'path', m.api_url, 'method', m.api_method, 'api_name', m.menu_name)
        ORDER BY m.api_url
    ), '[]'::json) INTO v_apis
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active AND m.api_url IS NOT NULL;

    SELECT COALESCE(json_agg(
        json_build_object('id', m.id, 'name', m.menu_name, 'parent_id', m.parent_id,
                          'path', m.router, 'icon', m.icon)
        ORDER BY m.order_num
    ), '[]'::json) INTO v_menus
    FROM iam_role_menu rm
    JOIN iam_menu m ON rm.menu_id = m.id
    WHERE rm.role_code = p_role_code AND m.is_active;

    RETURN json_build_object(
        'role_id', v_role.id,
        'role_code', v_role.role_code,
        'role_name', v_role.role_name,
        'type', v_role.type,
        'apis', v_apis,
        'menus', v_menus,
        'api_count', json_array_length(v_apis),
        'menu_count', json_array_length(v_menus)
    );
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_role_permissions(text) IS '获取角色权限（055 单表化: apis 段 = 角色菜单下挂接口，输出键 path/method/api_name 保持）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_role_permissions(text) TO authenticated;

-- 7.4 rpc_create_menu 重建（T3：+p_api_url/p_api_method/p_is_affix；
--     D8: button 禁传 router/component；D6: 端点成对 + 值域；
--     非 button 行 api_code/router/component/api_url 强制 NULL——Admin.NET CheckMenuParam 同款）
DROP FUNCTION IF EXISTS api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean);
CREATE FUNCTION api_v1_public.rpc_create_menu(
    p_menu_name text, p_parent_id uuid DEFAULT NULL, p_menu_type text DEFAULT 'menu',
    p_api_code text DEFAULT NULL, p_router text DEFAULT NULL, p_component text DEFAULT NULL,
    p_icon text DEFAULT NULL, p_order_num int DEFAULT 0, p_is_visible boolean DEFAULT true,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL,
    p_api_url text DEFAULT NULL, p_api_method text DEFAULT NULL, p_is_affix boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT has_permission('sys:menu:create') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF p_menu_name IS NULL OR trim(p_menu_name) = '' THEN
        RAISE EXCEPTION 'menu_name required' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    -- 040 单码制：button 必须 api_code
    IF p_menu_type = 'button' AND (p_api_code IS NULL OR trim(p_api_code) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：button 行禁传导航字段（RPC 友好报错 + 表级 CHECK 兜底）
    IF p_menu_type = 'button' AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    -- 端点仅 button 行使用（Admin.NET CheckMenuParam 语义：非 Btn 行不落端点）
    IF p_menu_type <> 'button' AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    INSERT INTO iam_menu (parent_id, menu_name, menu_type, api_code, router, component,
                          icon, order_num, is_visible,
                          remark, route_name, query,
                          is_link, is_iframe, redirect, keep_alive,
                          api_url, api_method, is_affix, created_by)
    VALUES (p_parent_id, p_menu_name, p_menu_type::iam_menu_type,
            CASE WHEN p_menu_type = 'button' THEN p_api_code ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_router END,
            CASE WHEN p_menu_type = 'button' THEN NULL ELSE p_component END,
            p_icon, p_order_num, p_is_visible,
            p_remark, p_route_name, p_query,
            COALESCE(p_is_link, p_menu_type = 'link'), COALESCE(p_is_iframe, false),
            p_redirect, COALESCE(p_keep_alive, true),
            CASE WHEN p_menu_type = 'button' THEN p_api_url ELSE NULL END,
            CASE WHEN p_menu_type = 'button' THEN p_api_method ELSE NULL END,
            COALESCE(p_is_affix, false), current_user_id())
    RETURNING id INTO v_id;
    PERFORM log_operate('menu', 'create', 'iam_menu', v_id::text,
                        'success', jsonb_build_object('name', p_menu_name, 'type', p_menu_type));
    RETURN json_build_object('ok', true, 'id', v_id);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单新增（sys:menu:create；055: +api_url/api_method/is_affix，D8 button 禁导航字段，D6 端点成对值域，非 button 行权限字段强制 NULL）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_create_menu(text, uuid, text, text, text, text, text, int, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

-- 7.5 rpc_update_menu 重建（同上；改类型时按最终类型应用字段归属规则）
DROP FUNCTION IF EXISTS api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean);
CREATE FUNCTION api_v1_public.rpc_update_menu(
    p_id uuid, p_parent_id uuid DEFAULT NULL, p_menu_name text DEFAULT NULL,
    p_menu_type text DEFAULT NULL, p_api_code text DEFAULT NULL, p_router text DEFAULT NULL,
    p_component text DEFAULT NULL, p_icon text DEFAULT NULL, p_order_num int DEFAULT NULL,
    p_is_active boolean DEFAULT NULL, p_is_visible boolean DEFAULT NULL,
    p_remark text DEFAULT NULL, p_route_name text DEFAULT NULL, p_query text DEFAULT NULL,
    p_is_link boolean DEFAULT NULL, p_is_iframe boolean DEFAULT NULL,
    p_redirect text DEFAULT NULL, p_keep_alive boolean DEFAULT NULL,
    p_api_url text DEFAULT NULL, p_api_method text DEFAULT NULL, p_is_affix boolean DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_menu_type iam_menu_type;
    v_api_code  text;
BEGIN
    IF NOT has_permission('sys:menu:update') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM iam_menu WHERE id = p_id) THEN
        RAISE EXCEPTION 'menu not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_id = p_id THEN
        RAISE EXCEPTION 'parent cannot be self' USING ERRCODE = '22023';
    END IF;
    IF p_menu_type IS NOT NULL AND p_menu_type NOT IN ('directory','menu','button','link') THEN
        RAISE EXCEPTION 'invalid menu_type' USING ERRCODE = '22023';
    END IF;
    SELECT menu_type, api_code INTO v_menu_type, v_api_code FROM iam_menu WHERE id = p_id;
    -- 040 单码制：最终类型为 button 必须 api_code
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (COALESCE(p_api_code, v_api_code) IS NULL OR trim(COALESCE(p_api_code, v_api_code)) = '') THEN
        RAISE EXCEPTION 'button menu requires api_code' USING ERRCODE = '22023';
    END IF;
    -- 055 D8：最终类型为 button 禁传导航字段
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type)
       AND (p_router IS NOT NULL OR p_component IS NOT NULL) THEN
        RAISE EXCEPTION 'button menu cannot have router/component' USING ERRCODE = '22023';
    END IF;
    -- 055 D6：端点成对 + 值域
    IF p_api_url IS NOT NULL AND (p_api_method IS NULL OR p_api_method NOT IN
       ('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS','*')) THEN
        RAISE EXCEPTION 'invalid api_method' USING ERRCODE = '22023';
    END IF;
    IF p_api_method IS NOT NULL AND p_api_url IS NULL THEN
        RAISE EXCEPTION 'api_url required with api_method' USING ERRCODE = '22023';
    END IF;
    IF (COALESCE(p_menu_type::iam_menu_type, v_menu_type) <> 'button'::iam_menu_type)
       AND (p_api_url IS NOT NULL OR p_api_method IS NOT NULL) THEN
        RAISE EXCEPTION 'api_url/api_method only for button' USING ERRCODE = '22023';
    END IF;
    UPDATE iam_menu SET
        parent_id   = COALESCE(p_parent_id, parent_id),
        menu_name   = COALESCE(p_menu_name, menu_name),
        menu_type   = COALESCE(p_menu_type::iam_menu_type, menu_type),
        -- 055：字段归属按最终类型（Admin.NET CheckMenuParam 语义）
        api_code    = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_code, api_code) ELSE NULL END,
        router      = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_router, router) END,
        component   = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN NULL ELSE COALESCE(p_component, component) END,
        icon        = COALESCE(p_icon, icon),
        order_num   = COALESCE(p_order_num, order_num),
        is_active   = COALESCE(p_is_active, is_active),
        is_visible  = COALESCE(p_is_visible, is_visible),
        remark      = COALESCE(p_remark, remark),
        route_name  = COALESCE(p_route_name, route_name),
        query       = COALESCE(p_query, query),
        is_link     = COALESCE(p_is_link, p_menu_type = 'link', is_link),
        is_iframe   = COALESCE(p_is_iframe, is_iframe),
        redirect    = COALESCE(p_redirect, redirect),
        keep_alive  = COALESCE(p_keep_alive, keep_alive),
        api_url     = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_url, api_url) ELSE NULL END,
        api_method  = CASE WHEN COALESCE(p_menu_type::iam_menu_type, v_menu_type) = 'button'::iam_menu_type
                           THEN COALESCE(p_api_method, api_method) ELSE NULL END,
        is_affix    = COALESCE(p_is_affix, is_affix),
        updated_at  = now(),
        updated_by  = current_user_id()
    WHERE id = p_id;
    PERFORM log_operate('menu', 'update', 'iam_menu', p_id::text);
    RETURN json_build_object('ok', true);
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean) IS '菜单修改（sys:menu:update；055: +api_url/api_method/is_affix，字段归属按最终类型——button 禁导航字段 D8，端点成对值域 D6）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_menu(uuid, uuid, text, text, text, text, text, text, int, boolean, boolean, text, text, text, boolean, boolean, text, boolean, text, text, boolean) TO authenticated;

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
    v_endpoints int;
    v_ch_super  boolean;
    v_ch_deny   boolean;
    v_role      text;
    v_code      text;
    v_ch_role   boolean;
    v_api_seg   int;
    v_menu_seg  int;
BEGIN
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

    SELECT count(*) INTO v_endpoints FROM iam_menu WHERE api_url IS NOT NULL;
    IF v_endpoints = 0 THEN RAISE EXCEPTION '055: 无转换出的端点按钮行'; END IF;

    -- 6. 行为断言（D3 单通道）
    PERFORM set_config('request.jwt.claims', '{"roles":["role_super_admin"]}', true);
    v_ch_super := has_permission('sys:menu:create');          -- 超管短路
    PERFORM set_config('request.jwt.claims', '{"roles":["__no_such_role__"]}', true);
    v_ch_deny  := NOT has_permission('sys:menu:create');      -- 未绑角色拒绝
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
END $$;
