-- api_v1/platform/rpc/rpc_search_login_logs.sql
-- D27: 登录日志查询按 organization_id + tenant_id 双维度。
-- organization_id IS NULL 放行：PostSignIn webhook 无组织上下文，sync_login_log_write
-- 落租户全局行（NULL），与 rls_policies 的全局行模式对齐；否则非超管恒 0 行。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_search_login_logs(
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
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
    v_org text := current_organization_id();
    v_tenant text := current_logto_tenant_id();
BEGIN
    IF NOT has_permission('platform:login-log:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF v_org IS NULL AND NOT is_super_admin() THEN
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
                    AND (is_super_admin() OR (l.tenant_id = v_tenant
                         AND (l.organization_id IS NULL OR l.organization_id = v_org)))),
        'limit', GREATEST(1, LEAST(p_limit, 100)),
        'offset', GREATEST(0, p_offset),
        'items', COALESCE((
            SELECT json_agg(row_to_json(u.*) ORDER BY u.created_at DESC)
            FROM (
                SELECT l.id, l.tenant_id, l.organization_id, l.user_id, l.username, l.login_type,
                       l.result, l.fail_reason, l.ip, l.user_agent, l.region,
                       l.logto_event, l.created_at
                FROM login_log l
                WHERE (p_user_id IS NULL OR l.user_id = p_user_id)
                  AND (p_result   IS NULL OR l.result = p_result)
                  AND (p_login_type IS NULL OR l.login_type ILIKE '%' || p_login_type || '%')
                  AND (p_region     IS NULL OR l.region ILIKE '%' || p_region || '%')
                  AND (p_from     IS NULL OR l.created_at >= p_from)
                  AND (p_to       IS NULL OR l.created_at <= p_to)
                  AND (is_super_admin() OR (l.tenant_id = v_tenant
                       AND (l.organization_id IS NULL OR l.organization_id = v_org)))
                ORDER BY l.created_at DESC
                LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
            ) u),
            '[]'::json)
    ) INTO v_result;
    RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_search_login_logs(text, text, timestamptz, timestamptz, int, int, text, text) TO authenticated;
