-- api_v1/platform/rpc/rpc_get_position_tree.sql
-- D27: 岗位树按 organization_id + tenant_id 双维度。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_get_position_tree()
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
        UNION ALL
        SELECT p.id, p.parent_id, p.pos_name, p.pos_code, p.sort_no, p.status,
               t.depth + 1, t.path_name::text || ' / ' || p.pos_name::text
        FROM position p JOIN tree t ON p.parent_id = t.id
        WHERE p.organization_id = current_organization_id()
          AND p.tenant_id = current_logto_tenant_id()
    )
    SELECT json_agg(row_to_json(x) ORDER BY x.path_name)
      INTO v_result
    FROM (SELECT id, parent_id, pos_name, pos_code, sort_no, status, depth, path_name
          FROM tree) x;
    RETURN COALESCE(v_result, '[]'::json);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_get_position_tree() TO authenticated;
