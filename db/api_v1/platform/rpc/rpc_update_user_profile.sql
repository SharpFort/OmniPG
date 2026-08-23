-- api_v1/platform/rpc/rpc_update_user_profile.sql
-- D27: 动态白名单排除 organization_id/tenant_id；建档写入 organization_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_user_profile(p_user_id text, p_updates jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_org text := current_organization_id();
    v_self   boolean;
    v_sql    text;
    v_col    text;
BEGIN
    IF p_user_id IS NULL OR p_updates IS NULL THEN
        RAISE EXCEPTION 'user_id and updates required' USING ERRCODE = '22023';
    END IF;
    v_self := (p_user_id = current_user_id());
    IF NOT v_self THEN
        IF NOT has_permission('platform:profile:update') THEN
            RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
        END IF;
        IF NOT is_super_admin()
           AND NOT EXISTS (SELECT 1 FROM platform.user_tenants
                           WHERE user_id = p_user_id AND organization_id = v_org
                             AND tenant_id = current_logto_tenant_id()) THEN
            RAISE EXCEPTION 'user not in organization' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    FOR v_col IN
        SELECT c.column_name
        FROM information_schema.columns c
        WHERE c.table_schema = 'platform' AND c.table_name = 'user_profile'
          AND c.column_name NOT IN
              ('user_id','organization_id','tenant_id','dept_id','created_at','updated_at',
               'deleted_at','created_by','updated_by','deleted_by')
          AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
    LOOP
        v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L, updated_at = now(), updated_by = %L WHERE user_id = %L',
                        v_col, v_col, current_user_id(), p_user_id);
        EXECUTE v_sql USING p_updates;
    END LOOP;
    IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM user_profile WHERE user_id = p_user_id) THEN
        INSERT INTO user_profile (user_id, organization_id, created_by)
        VALUES (p_user_id, v_org, current_user_id());
        FOR v_col IN
            SELECT c.column_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'platform' AND c.table_name = 'user_profile'
              AND c.column_name NOT IN
                  ('user_id','organization_id','tenant_id','dept_id','created_at','updated_at',
                   'deleted_at','created_by','updated_by','deleted_by')
              AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
        LOOP
            v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L WHERE user_id = %L',
                            v_col, v_col, p_user_id);
            EXECUTE v_sql USING p_updates;
        END LOOP;
    END IF;
    PERFORM log_operate('profile', 'update', 'user_profile', p_user_id,
                        'success', p_updates);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_user_profile(text, jsonb) TO authenticated;
