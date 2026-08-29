-- db/api_v1/platform/rpc/rpc_search_user_positions.sql
-- 用户-岗位搜索 RPC（后端 join 用户名/岗位名 + 分页，替代前端全量拉取后本地 join）
-- 072: 新增。SECURITY DEFINER + has_permission 档位（与 rpc_get_position_tree 同法）；
--   组织/租户隔离显式过滤（DEFINER 不走 RLS，须自带 current_organization_id/current_logto_tenant_id）。
-- p_query 匹配用户名/邮箱/姓名；p_position_name 匹配岗位名/层级路径；p_user_id 取某用户全部分配（编辑回填用）。

CREATE OR REPLACE FUNCTION api_v1_platform.search_user_positions(
    p_user_id text DEFAULT NULL,
    p_query text DEFAULT NULL,
    p_position_name text DEFAULT NULL,
    p_limit int DEFAULT 20,
    p_offset int DEFAULT 0
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_result json;
BEGIN
    IF NOT has_permission('platform:position:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    WITH RECURSIVE tree AS (
        SELECT id, parent_id, pos_name, pos_code, sort_no, status,
               1 AS depth, pos_name::text AS path_name
        FROM "position"
        WHERE parent_id IS NULL AND organization_id = current_organization_id()
          AND tenant_id = current_logto_tenant_id()
        UNION ALL
        SELECT p.id, p.parent_id, p.pos_name, p.pos_code, p.sort_no, p.status,
               t.depth + 1, t.path_name::text || ' / ' || p.pos_name::text
        FROM "position" p JOIN tree t ON p.parent_id = t.id
        WHERE p.organization_id = current_organization_id()
          AND p.tenant_id = current_logto_tenant_id()
    )
    SELECT json_build_object(
        'total', COALESCE((SELECT count(*)
             FROM user_position up
             LEFT JOIN users u ON u.id = up.user_id
             JOIN tree t ON t.id = up.position_id
             WHERE (p_user_id IS NULL OR up.user_id = p_user_id)
               AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                    OR u.primary_email ILIKE '%' || p_query || '%'
                    OR u.name ILIKE '%' || p_query || '%')
               AND (p_position_name IS NULL OR t.pos_name ILIKE '%' || p_position_name || '%'
                    OR t.path_name ILIKE '%' || p_position_name || '%')), 0),
        'limit', GREATEST(1, LEAST(p_limit, 100)),          -- 上限 100，与 035 档位统一
        'offset', GREATEST(0, p_offset),
        'items', COALESCE(
            (SELECT json_agg(row_to_json(x) ORDER BY x.created_at DESC, x.user_id, x.position_id)
             FROM (
                 SELECT up.user_id, up.position_id, up.tenant_id, up.organization_id,
                        up.is_primary, up.created_at, up.created_by,
                        u.username, u.primary_email AS email, u.name AS user_name,
                        t.pos_name, t.path_name,
                        cu.username AS created_by_username
                 FROM user_position up
                 LEFT JOIN users u ON u.id = up.user_id
                 JOIN tree t ON t.id = up.position_id
                 LEFT JOIN users cu ON cu.id = up.created_by
                 WHERE (p_user_id IS NULL OR up.user_id = p_user_id)
                   AND (p_query IS NULL OR u.username ILIKE '%' || p_query || '%'
                        OR u.primary_email ILIKE '%' || p_query || '%'
                        OR u.name ILIKE '%' || p_query || '%')
                   AND (p_position_name IS NULL OR t.pos_name ILIKE '%' || p_position_name || '%'
                        OR t.path_name ILIKE '%' || p_position_name || '%')
                 ORDER BY up.created_at DESC, up.user_id, up.position_id
                 LIMIT GREATEST(1, LEAST(p_limit, 100)) OFFSET GREATEST(0, p_offset)
             ) x),
            '[]'::json)
    ) INTO v_result;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.search_user_positions(text, text, text, int, int) IS
  '用户-岗位搜索（后端 join 用户名/岗位路径 + 分页；DEFINER + has_permission(platform:position:list)；显式组织/租户隔离）';
GRANT EXECUTE ON FUNCTION api_v1_platform.search_user_positions(text, text, text, int, int) TO authenticated;
