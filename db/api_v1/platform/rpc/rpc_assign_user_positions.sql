-- api_v1/platform/rpc/rpc_assign_user_positions.sql
-- D27: 岗位分配按 organization_id（业务组织）+ tenant_id（Logto 租户）双维度。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_assign_user_positions(
    p_user_id text, p_position_ids uuid[], p_primary_position_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_org text := current_organization_id();
BEGIN
    IF NOT has_permission('platform:position:assign') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.user_tenants
                   WHERE user_id = p_user_id AND organization_id = v_org
                     AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'user not in organization' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM user_position
    WHERE user_id = p_user_id AND organization_id = v_org AND tenant_id = current_logto_tenant_id();
    IF p_position_ids IS NOT NULL THEN
        INSERT INTO user_position (user_id, position_id, organization_id, tenant_id, is_primary, created_by)
        SELECT p_user_id, g, v_org, current_logto_tenant_id(),
               (g = p_primary_position_id), current_user_id()
        FROM unnest(p_position_ids) AS g;
    END IF;
    PERFORM log_operate('position', 'assign', 'user_position', p_user_id,
                        'success', jsonb_build_object('positions', p_position_ids));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_assign_user_positions(text, uuid[], uuid) TO authenticated;
