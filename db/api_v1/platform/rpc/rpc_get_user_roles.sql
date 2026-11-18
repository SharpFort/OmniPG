-- db/api_v1/platform/rpc/rpc_get_user_roles.sql
-- D27: 用户角色分配查询：p_organization_id（业务组织）+ tenant_id（Logto 租户）。

DROP FUNCTION IF EXISTS api_v1_platform.rpc_get_user_roles(text, text);
CREATE OR REPLACE FUNCTION api_v1_platform.rpc_get_user_roles(p_user_id text, p_organization_id text DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE
    v_org     text;
    v_tenant  text := current_logto_tenant_id();
    v_global     json;
    v_org_roles  json;
BEGIN
    IF NOT has_permission('platform:tenant-member:list') THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    v_org := COALESCE(p_organization_id, current_organization_id());
    IF v_org IS NULL THEN
        RAISE EXCEPTION 'organization required' USING ERRCODE = '22023';
    END IF;
    IF p_organization_id IS NOT NULL AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = current_user_id() AND organization_id = p_organization_id
                         AND tenant_id = v_tenant) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_global
    FROM (SELECT role_code, role_id, organization_id, tenant_id FROM platform.user_role
          WHERE user_id = p_user_id AND organization_id = '' AND tenant_id = v_tenant) x;

    SELECT COALESCE(json_agg(row_to_json(x) ORDER BY x.role_code), '[]'::json) INTO v_org_roles
    FROM (SELECT role_code, role_id, organization_id, tenant_id FROM platform.user_role
          WHERE user_id = p_user_id AND organization_id = v_org AND tenant_id = v_tenant) x;

    RETURN json_build_object(
        'user_id',    p_user_id,
        'tenant_id',  v_tenant,
        'organization_id', v_org,
        'global_roles', v_global,
        'tenant_roles', v_org_roles
    );
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_get_user_roles(text, text) TO authenticated;
