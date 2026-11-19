-- api_v1/platform/rpc/rpc_get_position_tree.sql
-- D27: 岗位树按 organization_id + tenant_id 双维度。

DROP FUNCTION IF EXISTS api_v1_platform.rpc_get_position_tree();
CREATE OR REPLACE FUNCTION api_v1_platform.rpc_get_position_tree(p_limit INTEGER DEFAULT 500)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_result json;
BEGIN
    IF NOT has_permission('platform:position:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    WITH RECURSIVE tree AS (
        SELECT id, parent_id, pos_name, pos_code, sort_no, status,
               1 AS depth, pos_name::text AS path_name
        FROM position
        WHERE parent_id IS NULL AND organization_id = current_organization_id()
          AND tenant_id = current_logto_tenant_id()
          -- 软删过滤（2026-11-19 修复）：锚点与递归分支均需排除，软删岗位不得入树
          AND deleted_at IS NULL
        UNION ALL
        SELECT p.id, p.parent_id, p.pos_name, p.pos_code, p.sort_no, p.status,
               t.depth + 1, t.path_name::text || ' / ' || p.pos_name::text
        FROM position p JOIN tree t ON p.parent_id = t.id
        WHERE p.organization_id = current_organization_id()
          AND p.tenant_id = current_logto_tenant_id()
          AND p.deleted_at IS NULL
          -- 环保护（2026-11-19 修复）：父链成环时递归深度上限兜底
          AND t.depth < 100
    )
    SELECT json_agg(row_to_json(x) ORDER BY x.path_name)
      INTO v_result
    FROM (SELECT id, parent_id, pos_name, pos_code, sort_no, status, depth, path_name
          -- 先排序后截断（2026-11-19 修复）：原 LIMIT 施加在无序子查询上，
          -- 截掉哪部分不确定，外层 ORDER BY 只重排已截断子集；
          -- id 作为同名 path_name 的稳定次序键，负数 p_limit 钳制为 1（避免 2201W 裸错误）
          FROM tree ORDER BY path_name, id
          LIMIT GREATEST(LEAST(COALESCE(p_limit, 500), 5000), 1)) x;
    RETURN COALESCE(v_result, '[]'::json);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_get_position_tree(INTEGER) TO authenticated;
