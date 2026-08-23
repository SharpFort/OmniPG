-- api_v1/platform/rpc/rpc_get_user_profile.sql
-- D27: 档案查询按 organization_id 成员约束，输出双列。

CREATE OR REPLACE FUNCTION api_v1_platform.rpc_get_user_profile(p_user_id text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, ext, pg_temp AS $$
DECLARE v_row json; v_org text := current_organization_id();
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'user_id required' USING ERRCODE = '22023';
    END IF;
    IF p_user_id <> current_user_id() AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM platform.user_tenants
                       WHERE user_id = p_user_id AND organization_id = v_org
                         AND tenant_id = current_logto_tenant_id()) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT COALESCE(row_to_json(p), '{}'::json) INTO v_row
    FROM user_profile p WHERE p.user_id = p_user_id;
    RETURN COALESCE(v_row, '{}'::json);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_platform.rpc_get_user_profile(text) TO authenticated;
