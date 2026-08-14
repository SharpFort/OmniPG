-- api_v1/public/rpc/rpc_get_user_roles.sql
-- FUNCTION: api_v1_public.rpc_get_user_roles（17 号文档归位：迁移 051_logto_guard_cleanup.sql 删定义段，本文件为唯一权威）
-- 回放终态: 051_logto_guard_cleanup.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_get_user_roles(p_user_id text, p_org_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_org        text;
    v_global     json;
    v_org_roles  json;
BEGIN
    IF NOT has_permission('sys:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_org_id, current_tenant_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    -- 同租户约束：跨租户查询仅超管可越权
    IF p_org_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_org_id) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_global
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = '') x;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_org_roles
    FROM (SELECT role_code, role_id FROM user_role
          WHERE user_id = p_user_id AND organization_id = v_org) x;

    RETURN json_build_object(
        'user_id',  p_user_id,
        'org_id',   v_org,
        'global_roles', v_global,
        'org_roles',    v_org_roles
    );
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_get_user_roles(text, text) TO authenticated;
