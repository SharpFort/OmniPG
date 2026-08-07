-- =============================================================================
-- 035_rpc_cleanup_unify.sql — 前端对齐方案 §1.2/§2.2 RPC 层修复
-- =============================================================================
-- 背景: 2026-08-07 前端对齐后端方案审查（§1.2 RPC 清单 B4-B7 + §2.2 API 层审查）
--   P1-B5: health_check 删除（20260707000014_auth_rpc_functions 遗留，全库无引用；
--           健康检查由 APISIX upstream / Pigsty 监控承担）
--   P1-B5: export_csv 删除（半成品：返回提示文本而非数据；SECURITY DEFINER +
--           p_columns/p_filter 裸 SQL 拼接 = 注入面；PostgREST 不支持流式 COPY，
--           导出走 GET /api_v1_public/{view}?select=... 原生能力（RLS 生效））
--   P1-B6: rpc_sync_user_roles 删除（Logto 官方 webhook 事件表核实：
--           User.*/Role.*/Organization.* 无"用户-角色绑定"事件（PUT /users/:id/roles
--           不触发任何 hook）→ 无法靠 Logto 推送；JIT 覆盖并入 ensure_user——
--           登录时 JWT claims roles 即 Logto 权威快照，随登录链路自动对齐，
--           前端零额外调用，业务端无主动同步）
--   P1-B5: import_csv 安全重写（原白名单 = api_v1_public 全部视图 - 3 个排除，
--           含镜像投影视图 role/user_role（简单视图可更新，DEFINER 可写穿
--           Logto 镜像表）；且值拼接无引号 = SQL 注入面 + JSON null 错位）
--           → 显式业务表白名单 + jsonb_populate_record 参数化列子集插入
--   P2-B4: search_users / search_audit_log 补 LIMIT 上限（原无上限）
--   P2-B4: 分页上限统一 100（rpc_search_login_logs 1000 / rpc_list_tenants 200 /
--           rpc_list_tenant_members 500 → 100；页面 10-50 条 + offset 翻页足够；
--           RPC 返回单一 JSON payload，PostgREST 无法对其 Range 分页，
--           自带 p_limit/p_offset 是唯一正确模式；GET /view 才用 PostgREST 原生分页）
--   P2-B6: tenant_admin 补绑 sys:tenant:list / sys:tenant-member:list（租户仅查看；
--           login-log 保持超管专属——030 绑定；用户/角色查看走 RLS 无门槛）
--   统一门槛三档: 新增 src 层 require_permission(text) / require_super_admin()
--           无门槛（INVOKER+RLS）/ 权限点（DEFINER+require_permission）/
--           超管（DEFINER+require_super_admin）——本轮重写函数应用，其余渐进
-- ⚠️ §2.2 审查补丁（同迁移追加）:
--   P0: get_user_permissions 删除（uuid 变量接收 text nanoid 调用必炸 22P02；
--       Casdoor 时代残留，三个输出均有替代：roles→get_current_user、
--       权限码→v_role_api_detail、菜单→get_user_menu；casbin_rule 视图保留——
--       pgTAP 测试引用，只读兼容视图无害）
--   P1: cleanup_expired_tokens 整链删除（死链：public.cleanup_expired_tokens()
--       全库无定义（029 wrapper 内部 PERFORM 目标不存在）；清理对象
--       sys_token_blacklist/sys_user_session 014 已删（D12 会话/吊销交 Logto）——
--       无可清理之物，cron 任务 cleanup-expired-tokens 一并删除（034 重调度作废）
--   P1: get_dept_tree(p_tenant_id) uuid → text（017 department.tenant_id text 化后
--       参数未同步；传值调用 text=uuid 无隐式 cast 必炸，传 NULL 短路不炸）
--   P1: rpc_list_cron_jobs/runs 补 GRANT authenticated（021 只授 web_anon，
--       与全库惯例不一致，authenticated 角色调用 42501）
--   P2: get_user_menu() 增加 menu_type 列（前端 §2.4 需过滤 button 菜单项，
--       原返回无此列无法区分；033 回填的按钮项会混入路由注册）
-- 联动: 024 删 sys:user-role:sync seed、025 删 §1 rpc_sync_user_roles、
--       029 删 §3 export_csv + §4 cleanup_expired_tokens + sys:export/sys:session:cleanup
--       seed、034 删 cleanup-expired-tokens 重调度段（源文件已改；已执行环境本迁移
--       DROP IF EXISTS / cron.unschedule 兜底，重放后不复活）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 统一权限门槛 helper（src 层 db/src/sys/functions/ 同款；此处保险重建）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION require_permission(p_code text) RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT has_permission(p_code) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;
COMMENT ON FUNCTION require_permission(text) IS '权限门槛统一入口（035）：has_permission 不通过即 42501；DEFINER 写/管理 RPC 统一调用';

CREATE OR REPLACE FUNCTION require_super_admin() RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
END;
$$;
COMMENT ON FUNCTION require_super_admin() IS '超管门槛统一入口（035）：平台级 RPC（pg_cron/会话清理等）统一调用';

-- ---------------------------------------------------------------------------
-- §2 删除废弃 RPC（030 先例：废弃功能直接删，防 apply-src 重放复活）
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_v1_public.health_check();
DROP FUNCTION IF EXISTS api_v1_public.export_csv(text, text, text);
DROP FUNCTION IF EXISTS api_v1_public.rpc_sync_user_roles(text);
DROP FUNCTION IF EXISTS api_v1_public.get_user_permissions();          -- §2.2 补丁 P0
DROP FUNCTION IF EXISTS api_v1_public.cleanup_expired_tokens();        -- §2.2 补丁 P1（死链）
DROP FUNCTION IF EXISTS api_v1_sys.cleanup_expired_tokens();           -- §2.2 补丁 P1（重放兜底）

-- 权限点清理（sys:export/sys:user-role:sync 已无函数、sys:session:cleanup 已无函数）
DELETE FROM iam_role_api
WHERE api_id IN (SELECT id FROM iam_api
                 WHERE api_code IN ('sys:export', 'sys:user-role:sync', 'sys:session:cleanup'));
DELETE FROM iam_api
WHERE api_code IN ('sys:export', 'sys:user-role:sync', 'sys:session:cleanup');

-- §2.2 补丁 P1：删除 cleanup-expired-tokens 定时任务（死链：无底层函数、无清理对象；
-- 034 重调度作废；cleanup-old-audit-logs 保留）
DO $$
BEGIN
    PERFORM cron.unschedule('cleanup-expired-tokens');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时忽略（pg_cron 扩展未装等）
END $$;

-- ---------------------------------------------------------------------------
-- §3 import_csv 安全重写
--     显式白名单：仅业务自主表（可批量导入）；镜像/审计/日志/绑定表排除
--     参数化：jsonb_populate_record 单行插入（类型安全、列名安全、JSON null → NULL）
--     保留: sys:import 门槛 + dry_run + per-row 错误收集 + log_operate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.import_csv(
    p_table_name text,
    p_data jsonb,
    p_dry_run boolean DEFAULT true
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_allow    text[] := ARRAY['department','position','user_position',
                               'dict_type','dict_data','iam_menu','iam_api'];
    v_item     jsonb;
    v_inserted int := 0;
    v_errors   text[] := '{}';
    v_cols     text;
    v_sql      text;
BEGIN
    PERFORM require_permission('sys:import');

    IF NOT (p_table_name = ANY(v_allow)) THEN
        RAISE EXCEPTION 'Table % not importable. Allowed: %',
            p_table_name, array_to_string(v_allow, ', ') USING ERRCODE = 'P0001';
    END IF;

    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'array'
       OR jsonb_array_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Import data must be a non-empty JSON array' USING ERRCODE = 'P0005';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_data)
    LOOP
        BEGIN
            IF jsonb_typeof(v_item) <> 'object'
               OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_item)) THEN
                RAISE EXCEPTION 'row must be a non-empty JSON object';
            END IF;

            -- 列子集插入：仅 JSON 提供的键（quote_ident 防注入），
            -- 缺失列（id/created_at 等）走表 DEFAULT——jsonb_populate_record
            -- 全列填充会把 NULL 显式传入导致 NOT NULL 冲突（PGlite 验证发现）
            v_cols := (SELECT string_agg(quote_ident(k), ', ')
                       FROM jsonb_object_keys(v_item) AS k);
            v_sql := format('INSERT INTO api_v1_public.%I (%s) ' ||
                            'SELECT %s FROM jsonb_populate_record(NULL::api_v1_public.%I, $1)',
                            p_table_name, v_cols, v_cols, p_table_name);

            IF NOT p_dry_run THEN
                EXECUTE v_sql USING v_item;
                v_inserted := v_inserted + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_errors := array_append(v_errors, format('Row %s: %s', v_item::text, SQLERRM));
        END;
    END LOOP;

    PERFORM log_operate('import', 'import', p_table_name, NULL::text, 'success',
                        jsonb_build_object('total', jsonb_array_length(p_data),
                                           'inserted', v_inserted));
    RETURN json_build_object('table', p_table_name,
                             'total', jsonb_array_length(p_data),
                             'inserted', v_inserted,
                             'errors', v_errors,
                             'dry_run', p_dry_run);
END;
$$;
COMMENT ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) IS '通用导入（035 重写：显式业务表白名单 + jsonb_populate_record 参数化列子集；sys:import）';
GRANT EXECUTE ON FUNCTION api_v1_public.import_csv(text, jsonb, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- §4 search_users / search_audit_log 补 LIMIT 上限（原无上限，p_limit 可传任意大）
--     RPC 分页模式: 自带 p_limit/p_offset（PostgREST 无法对 RPC 结果 Range 分页）
--     上限统一 100: 页面 10-50 条，offset 翻页；防误传大 limit 拉全表
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.search_users(
    p_query text DEFAULT NULL,
    p_status text DEFAULT NULL,
    p_dept_id uuid DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_public.v_user_list u2
                  WHERE (p_query IS NULL OR u2.username ILIKE '%' || p_query || '%' OR u2.email ILIKE '%' || p_query || '%')
                    AND (p_status IS NULL OR (p_status = 'active' AND u2.is_active = TRUE) OR (p_status = 'inactive' AND u2.is_active = FALSE))
                    AND (p_dept_id IS NULL OR u2.dept_id = p_dept_id)),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_public.v_user_list u2
                 WHERE (p_query IS NULL OR u2.username ILIKE '%' || p_query || '%' OR u2.email ILIKE '%' || p_query || '%')
                   AND (p_status IS NULL OR (p_status = 'active' AND u2.is_active = TRUE) OR (p_status = 'inactive' AND u2.is_active = FALSE))
                   AND (p_dept_id IS NULL OR u2.dept_id = p_dept_id)
                 ORDER BY u2.created_at DESC
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) u),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.search_users(text, text, uuid, int, int) IS '分页搜索用户（035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';
GRANT EXECUTE ON FUNCTION api_v1_public.search_users(text, text, uuid, int, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_public.search_audit_log(
    p_query text DEFAULT NULL,
    p_table_name text DEFAULT NULL,
    p_operation text DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    SELECT json_build_object(
        'total', (SELECT COUNT(*) FROM api_v1_public.v_audit_log_detail
                  WHERE (p_table_name IS NULL OR table_name = p_table_name)
                    AND (p_operation IS NULL OR operation = p_operation)
                    AND (p_query IS NULL OR old_data::text ILIKE '%' || p_query || '%' OR new_data::text ILIKE '%' || p_query || '%')),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(a.*) ORDER BY a.created_at DESC)
             FROM (
                 SELECT * FROM api_v1_public.v_audit_log_detail
                 WHERE (p_table_name IS NULL OR table_name = p_table_name)
                   AND (p_operation IS NULL OR operation = p_operation)
                   AND (p_query IS NULL OR old_data::text ILIKE '%' || p_query || '%' OR new_data::text ILIKE '%' || p_query || '%')
                 ORDER BY created_at DESC
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) a),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.search_audit_log(text, text, text, int, int) IS '搜索审计日志（035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';
GRANT EXECUTE ON FUNCTION api_v1_public.search_audit_log(text, text, text, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §5 rpc_search_login_logs 重写（023 版 + 上限统一 100；DEFINER + 权限点档）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_search_login_logs(
    p_user_id  text DEFAULT NULL,
    p_result   text DEFAULT NULL,
    p_from     timestamptz DEFAULT NULL,
    p_to       timestamptz DEFAULT NULL,
    p_limit    int DEFAULT 50,
    p_offset   int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
    v_tenant text := current_tenant_id();
BEGIN
    -- 权限门槛：超管或具备登录日志查询权限点（023 原逻辑）
    IF NOT has_permission('sys:login-log:list') THEN
        RAISE EXCEPTION 'permission denied'
            USING ERRCODE = '42501';
    END IF;

    IF v_tenant IS NULL AND NOT is_super_admin() THEN
        RETURN json_build_object('total', 0, 'limit', p_limit, 'offset', p_offset, 'items', '[]'::json);
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM login_log l
                  WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                    AND (p_result   IS NULL OR l.result = p_result)
                    AND (p_from     IS NULL OR l.created_at >= p_from)
                    AND (p_to       IS NULL OR l.created_at <= p_to)
                    AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
            FROM (
                SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type,
                       l.result, l.fail_reason, l.ip, l.user_agent, l.region,
                       l.logto_event, l.created_at
                FROM login_log l
                WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                  AND (p_result   IS NULL OR l.result = p_result)
                  AND (p_from     IS NULL OR l.created_at >= p_from)
                  AND (p_to       IS NULL OR l.created_at <= p_to)
                  AND (is_super_admin() OR EXISTS (
                            SELECT 1 FROM user_tenants ut
                            WHERE ut.user_id = l.user_id
                              AND ut.organization_id = v_tenant))
                ORDER BY l.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) u),
            '[]'::json)
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int) IS '登录日志分页查询（035: 上限统一 100；sys:login-log:list；租户成员过滤）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §6 rpc_list_tenants / rpc_list_tenant_members 重写（025 版 + 上限统一 100）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_tenants(
    p_query text DEFAULT NULL, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('sys:tenant:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT json_build_object(
        'total', (SELECT count(*) FROM tenants t
                  WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC)
            FROM (
                SELECT t.id, t.name, t.description, t.created_at,
                       (SELECT count(*) FROM user_tenants ut
                        WHERE ut.organization_id = t.id) AS member_count
                FROM tenants t
                WHERE p_query IS NULL OR t.name ILIKE '%' || p_query || '%'
                ORDER BY t.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_list_tenants(text, int, int) IS '租户列表（035: 上限统一 100；sys:tenant:list）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_tenants(text, int, int) TO authenticated;

CREATE OR REPLACE FUNCTION api_v1_public.rpc_list_tenant_members(
    p_org_id text DEFAULT NULL, p_query text DEFAULT NULL,
    p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_result json; v_org text;
BEGIN
    IF NOT has_permission('sys:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT json_build_object(
        'total', (SELECT count(*) FROM user_tenants ut
                  WHERE ut.organization_id = v_org
                    AND (p_query IS NULL OR EXISTS (
                        SELECT 1 FROM users u WHERE u.id = ut.user_id
                        AND (u.username ILIKE '%' || p_query || '%'
                          OR u.primary_email ILIKE '%' || p_query || '%')))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限统一 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(x) ORDER BY x.joined_at DESC)
            FROM (
                SELECT u.id AS user_id, u.username, u.primary_email AS email,
                       u.primary_phone AS phone, u.name, u.avatar,
                       (NOT u.is_suspended) AS is_active,
                       ut.created_at AS joined_at
                FROM user_tenants ut
                JOIN users u ON u.id = ut.user_id
                WHERE ut.organization_id = v_org
                  AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%')
                ORDER BY ut.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) x), '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END $$;
COMMENT ON FUNCTION api_v1_public.rpc_list_tenant_members(text, text, int, int) IS '租户成员列表（035: 上限统一 100；sys:tenant-member:list）';
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_tenant_members(text, text, int, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §7 ensure_user 增加 user_role 分配镜像 JIT 覆盖
--     登录链路（前端回调调 ensure_user）即 Logto 权威推送（JWT claims roles），
--     替代 rpc_sync_user_roles（035 删除）；未登录用户数据陈旧由 P2 对账任务可选兜底
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_claims jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub    text;
    v_org    text;
    v_roles  text[];
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO users (id, username, name, avatar, is_suspended)
    VALUES (
        v_sub,
        COALESCE(v_claims->>'username', ''),
        COALESCE(v_claims->>'name', ''),
        COALESCE(v_claims->>'avatar', ''),
        false
    )
    ON CONFLICT (id) DO UPDATE SET
        username = EXCLUDED.username,
        name     = EXCLUDED.name,
        avatar   = EXCLUDED.avatar,
        updated_at = now();

    -- JIT 兜底：组织 token 携带 organization_id 时补建 profile（租户归属）
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, tenant_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id;
    END IF;

    -- 035: user_role 分配镜像 JIT 覆盖（claims roles = Logto 当前权威，全量覆盖）
    v_roles := ARRAY(SELECT jsonb_array_elements_text(v_claims->'roles'));
    DELETE FROM user_role WHERE user_id = v_sub;
    IF v_roles IS NOT NULL AND cardinality(v_roles) > 0 THEN
        INSERT INTO user_role (user_id, role_code)
        SELECT v_sub, g FROM unnest(v_roles) AS g
        ON CONFLICT (user_id, role_code) DO NOTHING;
    END IF;

    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_public.ensure_user() IS '登录 JIT 兜底建档 + 角色镜像覆盖（035: user_role 随 claims 全量覆盖，替代 rpc_sync_user_roles）';
GRANT EXECUTE ON FUNCTION api_v1_public.ensure_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- §8 tenant_admin 补绑租户查看权限点（B6：项目段租户仅查看）
--     登录日志（sys:login-log:list）保持超管专属（030 绑定）
-- ---------------------------------------------------------------------------
INSERT INTO iam_role_api (role_code, api_id)
SELECT 'tenant_admin', id FROM iam_api
WHERE api_code IN ('sys:tenant:list', 'sys:tenant-member:list')
ON CONFLICT (role_code, api_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- §9 §2.2 补丁：rpc_list_cron_jobs/runs 补 GRANT authenticated
--     021 只授 web_anon（全库孤例）；authenticated 角色调用 42501；
--     超管门槛在函数内部（is_super_admin），此处只需执行权限
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_cron_jobs() TO authenticated;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_list_cron_job_runs(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- §10 §2.2 补丁：get_dept_tree 参数 uuid → text
--     017 把 department.tenant_id 改 text 后参数未同步；传值调用
--     text = uuid 无隐式 cast 必炸（传 NULL 时 OR 短路不炸，掩盖问题）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_public.get_dept_tree(p_tenant_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    WITH RECURSIVE dept_tree AS (
        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            1 AS level,
            ARRAY[d.id] AS path_ids,
            ARRAY[d.dept_name] AS path_names
        FROM public.department d
        WHERE d.parent_id IS NULL AND d.deleted_at IS NULL
          AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)

        UNION ALL

        SELECT
            d.id, d.dept_name, d.parent_id, d.sort_order, d.is_active,
            dt.level + 1,
            dt.path_ids || d.id,
            dt.path_names || d.dept_name
        FROM public.department d
        JOIN dept_tree dt ON d.parent_id = dt.id
        WHERE d.deleted_at IS NULL AND dt.level < 10
    )
    SELECT COALESCE(json_agg(
        json_build_object(
            'id', dt.id,
            'dept_name', dt.dept_name,
            'parent_id', dt.parent_id,
            'sort_order', dt.sort_order,
            'is_active', dt.is_active,
            'level', dt.level,
            'path', array_to_string(dt.path_names, ' > ')
        ) ORDER BY dt.path_ids
    ), '[]'::json) INTO v_result
    FROM dept_tree dt;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_public.get_dept_tree(text) IS '获取部门树形结构（035: p_tenant_id 改 text，对齐 department.tenant_id text 化）';
GRANT EXECUTE ON FUNCTION api_v1_public.get_dept_tree(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- §11 §2.2 补丁：get_user_menu() 增加 menu_type/perms/is_visible/component 列
--     前端 §2.4 需按 menu_type 过滤 button 按钮项（033 回填的按钮项
--     若绑定进 iam_role_menu 会混入路由注册）；原返回无此列无法区分。
--     035 补丁（用户拍板 2026-08-07）：+component 列——033 已回填
--     path→组件路径（regexp_replace(path,'^/','')||'/index'），但原返回
--     不下发 → 前端只能靠 11 项硬编码映射表，新菜单必改前端代码；
--     补列后前端映射表降级为兜底（component 为空时用）。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_user_menu()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles jsonb;
    v_menu_tree json;
BEGIN
    v_roles := current_setting('request.jwt.claims', true)::jsonb->'roles';

    IF v_roles IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_roles)) THEN
        RETURN '[]'::json;
    END IF;

    WITH RECURSIVE menu_cte AS (
        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.menu_type, m.perms, m.is_visible, m.component, m.order_num
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.parent_id IS NULL AND m.is_active

        UNION ALL

        SELECT
            m.id, m.parent_id, m.menu_name AS name, m.path, m.icon,
            m.menu_type, m.perms, m.is_visible, m.component, m.order_num
        FROM iam_menu m
        JOIN iam_role_menu rm ON m.id = rm.menu_id
        JOIN menu_cte c ON m.parent_id = c.id
        WHERE rm.role_code IN (SELECT jsonb_array_elements_text(v_roles))
          AND m.is_active
    )
    SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) INTO v_menu_tree
    FROM (
        SELECT
            c.id, c.parent_id, c.name, c.path,
            c.menu_type, c.perms, c.is_visible, c.component,
            json_build_object('title', c.name, 'icon', c.icon) AS meta
        FROM menu_cte c
        ORDER BY c.order_num
    ) t;

    RETURN v_menu_tree;
END;
$$;
COMMENT ON FUNCTION get_user_menu() IS '获取用户菜单树（035: +menu_type/perms/is_visible/component——前端按 menu_type 过滤 button、component 直用 033 回填值，映射表仅兜底）';

-- ---------------------------------------------------------------------------
-- §12 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_deleted    int;   -- 已删函数残留（期望 0 = 不存在）
    v_perms      int;   -- 残留权限点（期望 0）
    v_import     int;   -- import_csv 安全特征（期望 2: require_permission + jsonb_populate_record）
    v_limits     int;   -- LIMIT 上限函数数（期望 5: search_users/search_audit_log/login_logs/tenants/members）
    v_jit        int;   -- ensure_user JIT 特征（期望 1）
    v_tenant_bind int;  -- tenant_admin 租户权限点绑定数（期望 2）
    v_helper     int;   -- helper 函数数（期望 2）
    v_dept_param int;   -- get_dept_tree 参数 text 化（期望 1）
    v_menu_type  int;   -- get_user_menu 含 menu_type（期望 1）
    v_cron_grant int;   -- cron RPC authenticated 可执行（期望 2）
    v_cron_cleanup int; -- cleanup-expired-tokens 任务残留（期望 0）
BEGIN
    SELECT count(*) INTO v_deleted FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('health_check','export_csv','rpc_sync_user_roles',
                        'get_user_permissions','cleanup_expired_tokens');
    SELECT count(*) INTO v_perms FROM iam_api
      WHERE api_code IN ('sys:export','sys:user-role:sync','sys:session:cleanup');
    SELECT count(*) INTO v_import FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'import_csv'
        AND prosrc LIKE '%require_permission%'
        AND prosrc LIKE '%jsonb_populate_record%';
    SELECT count(*) INTO v_limits FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname IN ('search_users','search_audit_log','rpc_search_login_logs',
                        'rpc_list_tenants','rpc_list_tenant_members')
        AND prosrc LIKE '%LEAST(p_limit, 100)%';
    SELECT count(*) INTO v_jit FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'ensure_user'
        AND prosrc LIKE '%user_role%';
    SELECT count(*) INTO v_tenant_bind FROM iam_role_api ra
      JOIN iam_api a ON a.id = ra.api_id
      WHERE ra.role_code = 'tenant_admin'
        AND a.api_code IN ('sys:tenant:list','sys:tenant-member:list');
    SELECT count(*) INTO v_helper FROM pg_proc
      WHERE proname IN ('require_permission','require_super_admin');
    SELECT count(*) INTO v_dept_param FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_public' AND p.proname = 'get_dept_tree'
        AND pg_get_function_arguments(p.oid) LIKE '%text%';
    SELECT count(*) INTO v_menu_type FROM pg_proc
      WHERE proname = 'get_user_menu'
        AND prosrc LIKE '%menu_type%';
    SELECT count(*) INTO v_cron_grant FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_public'
        AND p.proname IN ('rpc_list_cron_jobs','rpc_list_cron_job_runs')
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
    SELECT count(*) INTO v_cron_cleanup FROM cron.job
      WHERE jobname = 'cleanup-expired-tokens';
    RAISE NOTICE '035: 已删函数残留=%（期望0） 权限点残留=%（期望0） import安全特征=%（期望2） LIMIT上限函数=%（期望5） ensure_user_JIT=%（期望1） tenant_admin绑定=%（期望2） helper=%（期望2） dept参数text=%（期望1） menu含menu_type=%（期望1） cron授权=%（期望2） cleanup任务残留=%（期望0）',
        v_deleted, v_perms, v_import, v_limits, v_jit, v_tenant_bind, v_helper,
        v_dept_param, v_menu_type, v_cron_grant, v_cron_cleanup;
END $$;
