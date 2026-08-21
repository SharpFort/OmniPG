-- api_v1/public/rpc/rpc_update_user_profile.sql
-- FUNCTION: api_v1_public.rpc_update_user_profile（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_update_user_profile(p_user_id text, p_updates jsonb)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_tenant text := current_tenant_id();
    v_self   boolean;
    v_sql    text;
    v_col    text;
BEGIN
    IF p_user_id IS NULL OR p_updates IS NULL THEN
        RAISE EXCEPTION 'user_id and updates required' USING ERRCODE = '22023';
    END IF;
    -- 权限：本人改自己（免权限点）或超管/本租户管理成员（需权限点）
    v_self := (p_user_id = current_user_id());
    IF NOT v_self THEN
        IF NOT has_permission('public:profile:update') THEN
            RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
        END IF;
        IF NOT is_super_admin()
           AND NOT EXISTS (SELECT 1 FROM user_tenants
                           WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
            RAISE EXCEPTION 'user not in tenant' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- 动态列白名单：仅允许 user_profile 的业务列（排除主键/租户/审计列）
    FOR v_col IN
        SELECT c.column_name
        FROM information_schema.columns c
        WHERE c.table_schema = 'platform' AND c.table_name = 'user_profile'
          AND c.column_name NOT IN
              ('user_id','tenant_id','dept_id','created_at','updated_at',
               'deleted_at','created_by','updated_by','deleted_by')
          AND jsonb_typeof(p_updates -> c.column_name) IS NOT NULL
    LOOP
        v_sql := format('UPDATE user_profile SET %I = $1::jsonb->%L, updated_at = now(), updated_by = %L WHERE user_id = %L',
                        v_col, v_col, current_user_id(), p_user_id);
        EXECUTE v_sql USING p_updates;
    END LOOP;
    -- 档案行不存在则建档（JIT 语义）
    IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM user_profile WHERE user_id = p_user_id) THEN
        INSERT INTO user_profile (user_id, tenant_id, created_by)
        VALUES (p_user_id, v_tenant, current_user_id());
        -- 再执行一次白名单更新（简化：仅重放首轮）
        FOR v_col IN
            SELECT c.column_name
            FROM information_schema.columns c
            WHERE c.table_schema = 'platform' AND c.table_name = 'user_profile'
              AND c.column_name NOT IN
                  ('user_id','tenant_id','dept_id','created_at','updated_at',
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
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_update_user_profile(text, jsonb) TO authenticated;
