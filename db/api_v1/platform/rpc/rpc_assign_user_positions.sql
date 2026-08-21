-- api_v1/platform/rpc/rpc_assign_user_positions.sql
-- FUNCTION: api_v1_platform.rpc_assign_user_positions（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_assign_user_positions(
    p_user_id text, p_position_ids uuid[], p_primary_position_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_tenant text := current_tenant_id();
BEGIN
    IF NOT has_permission('platform:position:assign') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    -- 目标用户必须是本租户成员
    IF NOT EXISTS (SELECT 1 FROM user_tenants
                   WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
    END IF;
    -- 全量覆盖分配
    DELETE FROM user_position
    WHERE user_id = p_user_id AND tenant_id = v_tenant;
    IF p_position_ids IS NOT NULL THEN
        INSERT INTO user_position (user_id, position_id, tenant_id, is_primary, created_by)
        SELECT p_user_id, g, v_tenant,
               (g = p_primary_position_id), current_user_id()
        FROM unnest(p_position_ids) AS g;
    END IF;
    PERFORM log_operate('position', 'assign', 'user_position', p_user_id,
                        'success', jsonb_build_object('positions', p_position_ids));
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_assign_user_positions(text, uuid[], uuid) TO authenticated;
