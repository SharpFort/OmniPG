-- db/api_v1/platform/rpc/rpc_search_users.sql
-- 分页搜索用户 RPC（支持关键词、状态、部门筛选）
-- 来源: 20260707000015_system_management_api.sql → 035 LIMIT 上限统一 100
-- 权限档位: 无门槛（SECURITY INVOKER + RLS 行级隔离；无需权限点）
-- 分页模式: RPC 自带 p_limit/p_offset（PostgREST 无法对 RPC 结果 Range 分页）

CREATE OR REPLACE FUNCTION api_v1_platform.search_users(
    p_query text DEFAULT NULL,
    p_status text DEFAULT NULL,
    p_dept_id uuid DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    -- P-3l（2026-11-20，阶段 4）：count/items 双段各展开一次 v_user_list（join +
    -- 过滤两遍）→ 合并单扫描分页（page CTE + count(*) OVER() 窗口计数；
    -- items 子查询显式列清单剥离计数列，输出列集与原版一致）
    WITH page AS (
        SELECT u2.*, count(*) OVER () AS v_total
        FROM api_v1_platform.v_user_list u2
        WHERE (p_query IS NULL OR u2.username ILIKE '%' || p_query || '%' OR u2.email ILIKE '%' || p_query || '%')
          AND (p_status IS NULL OR (p_status = 'active' AND u2.is_active = TRUE) OR (p_status = 'inactive' AND u2.is_active = FALSE))
          AND (p_dept_id IS NULL OR u2.dept_id = p_dept_id)
        ORDER BY u2.created_at DESC
        LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
    )
    SELECT json_build_object(
        'total', COALESCE((SELECT max(v_total) FROM page), 0),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 035: 上限 100
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(u) ORDER BY u.created_at DESC)
             FROM (
                 SELECT id, username, email, phone, name, tenant_id,
                        organization_id, organization_name, tenant_name,
                        dept_name, is_active, created_at, updated_at,
                        deleted_at, organizations
                 FROM page
             ) u),
            '[]'::json
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.search_users(text, text, uuid, int, int) IS '分页搜索用户（035: LIMIT 上限 100；INVOKER + RLS 无门槛档）';
GRANT EXECUTE ON FUNCTION api_v1_platform.search_users(text, text, uuid, int, int) TO authenticated;
