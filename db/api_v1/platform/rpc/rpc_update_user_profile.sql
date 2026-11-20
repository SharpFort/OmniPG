-- api_v1/platform/rpc/rpc_update_user_profile.sql
-- D27: 动态白名单排除 organization_id/tenant_id；建档写入 organization_id。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_update_user_profile(p_user_id text, p_updates jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_org text := current_organization_id();
    -- P-3f 附带（2026-11-20，阶段 4，P-2d 模式收官）：tenant 提局部变量
    --（原 current_logto_tenant_id 在成员校验与建档 INSERT 两处重复解析 claims）
    v_tenant text := current_logto_tenant_id();
    v_self   boolean;
    v_sql    text;
    v_col    text;
    v_data_type   text;
    v_udt_schema  text;
    v_udt_name    text;
    v_expr        text;
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
                             AND tenant_id = v_tenant) THEN
            RAISE EXCEPTION 'user not in organization' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- 1. 保证档案记录存在（原子 Upsert，防止首次建档丢失与并发冲突）
    INSERT INTO user_profile (user_id, organization_id, tenant_id, created_by)
    VALUES (p_user_id, v_org, v_tenant, current_user_id())
    ON CONFLICT (user_id) DO NOTHING;

    -- 2. 动态扫描白名单字段，合并为单条 UPDATE 执行（消除 N 次单独更新性能瓶颈）
    DECLARE
        v_set_clauses text[] := ARRAY[]::text[];
    BEGIN
        FOR v_col, v_data_type, v_udt_schema, v_udt_name IN
            SELECT c.column_name, c.data_type, c.udt_schema, c.udt_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'platform' AND c.table_name = 'user_profile'
              AND c.column_name NOT IN
                  ('user_id','organization_id','tenant_id','dept_id','created_at','updated_at',
                   'deleted_at','created_by','updated_by','deleted_by')
              AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
        LOOP
            v_expr := CASE
                WHEN v_data_type = 'USER-DEFINED' THEN
                    format('($1::jsonb->>%L)::%I.%I', v_col, v_udt_schema, v_udt_name)
                WHEN v_data_type = 'date' THEN
                    format('($1::jsonb->>%L)::date', v_col)
                WHEN v_data_type = 'ARRAY' THEN
                    format('ARRAY(SELECT jsonb_array_elements_text($1::jsonb->%L))', v_col)
                WHEN v_data_type = 'jsonb' THEN
                    format('($1::jsonb->%L)', v_col)
                ELSE
                    format('($1::jsonb->>%L)', v_col)
            END;
            v_set_clauses := array_append(v_set_clauses, format('%I = %s', v_col, v_expr));
        END LOOP;

        IF cardinality(v_set_clauses) > 0 THEN
            v_sql := format('UPDATE user_profile SET %s, updated_at = now(), updated_by = %L WHERE user_id = %L',
                            array_to_string(v_set_clauses, ', '), current_user_id(), p_user_id);
            EXECUTE v_sql USING p_updates;
        END IF;
    END;

    PERFORM log_operate('profile', 'update', 'user_profile', p_user_id,
                        'success', p_updates);
    RETURN json_build_object('ok', true);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_update_user_profile(text, jsonb) TO authenticated;
