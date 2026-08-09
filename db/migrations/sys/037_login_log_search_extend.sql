-- =============================================================================
-- 037_login_log_search_extend.sql — 登录日志搜索增强（登录方式/地区过滤）
-- =============================================================================
-- 背景: 2026-08-09 OmniAdmin 登录日志页新增 user_agent/logto_event 列展示 +
--   登录方式/地区搜索框（用户拍板；与 036 审计日志搜索增强同批规范）
--   数据说明: login_type = user.identities 首个 key（password/sms/connectorId/unknown）；
--     region = ip2region 离线库（国家|省|市|ISP，未命中 NULL，020）
--   方案（与 036 同构，左闭右闭时间约定不变）:
--     p_login_type → login_type ILIKE '%'||p_login_type||'%'（模糊；连接器 ID 记不全）
--     p_region     → region     ILIKE '%'||p_region||'%'     （模糊；多段格式便于分段检索）
--   兼容性: 新参数全部 DEFAULT NULL，旧调用不受影响；签名 6 参 → 8 参，
--   旧 6 参重载必须 DROP（否则 PGRST203 候选函数歧义，见 027/036 教训）
-- =============================================================================

CREATE OR REPLACE FUNCTION api_v1_public.rpc_search_login_logs(
    p_user_id  text DEFAULT NULL,
    p_result   text DEFAULT NULL,
    p_from     timestamptz DEFAULT NULL,
    p_to       timestamptz DEFAULT NULL,
    p_limit    int DEFAULT 50,
    p_offset   int DEFAULT 0,
    p_login_type text DEFAULT NULL,
    p_region   text DEFAULT NULL
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
                    AND (p_login_type IS NULL OR l.login_type ILIKE '%' || p_login_type || '%')
                    AND (p_region     IS NULL OR l.region ILIKE '%' || p_region || '%')
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
                  AND (p_login_type IS NULL OR l.login_type ILIKE '%' || p_login_type || '%')
                  AND (p_region     IS NULL OR l.region ILIKE '%' || p_region || '%')
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

-- 旧 6 参重载删除（CREATE OR REPLACE 不同参数列表 = 新增重载，旧版残留 → PGRST203）
DROP FUNCTION IF EXISTS api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int);

COMMENT ON FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int, text, text) IS
    '登录日志分页查询（037: 新增登录方式/地区模糊过滤；035: 上限统一 100；sys:login-log:list；租户成员过滤）';

GRANT EXECUTE ON FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int, text, text) TO authenticated;

-- 属主保持 app_owner（迁移经 postgres 超管执行时防 SECURITY DEFINER 提权漂移）
ALTER FUNCTION api_v1_public.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int, text, text) OWNER TO app_owner;

-- =============================================================================
-- 验证块: 新签名存在 / 旧重载已删 / 权限已授 / 属主正确
-- =============================================================================
DO $$
DECLARE
    v_new   int;
    v_old   int;
    v_grant int;
    v_owner int;
BEGIN
    -- ⚠️ 本 PG 版本 pg_get_function_identity_arguments 含参数名（036 验证块因此从未真正跑过；
    --    此处按实际输出格式匹配，参数名写全）
    SELECT count(*) INTO v_new FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'rpc_search_login_logs'
        AND pg_get_function_identity_arguments(oid) = 'p_user_id text, p_result text, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer, p_login_type text, p_region text';
    SELECT count(*) INTO v_old FROM pg_proc
      WHERE pronamespace = 'api_v1_public'::regnamespace
        AND proname = 'rpc_search_login_logs'
        AND pg_get_function_identity_arguments(oid) = 'p_user_id text, p_result text, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer, p_offset integer';
    SELECT count(*) INTO v_grant FROM information_schema.role_routine_grants
      WHERE routine_schema = 'api_v1_public'
        AND routine_name = 'rpc_search_login_logs'
        AND grantee = 'authenticated';
    SELECT count(*) INTO v_owner FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
      WHERE p.pronamespace = 'api_v1_public'::regnamespace
        AND p.proname = 'rpc_search_login_logs'
        AND r.rolname = 'app_owner';
    RAISE NOTICE '037: 新签名=%（期望1） 旧重载=%（期望0） authenticated授权=%（期望1） 属主app_owner=%（期望1）',
        v_new, v_old, v_grant, v_owner;
    IF v_new <> 1 OR v_old <> 0 OR v_grant < 1 OR v_owner <> 1 THEN
        RAISE EXCEPTION '037: 验证失败 new=% old=% grant=% owner=%', v_new, v_old, v_grant, v_owner;
    END IF;
END $$;

-- PostgREST 模式缓存刷新（DDL 后必须，否则旧计划继续服务）
SELECT pg_notify('pgrst', 'reload schema');
