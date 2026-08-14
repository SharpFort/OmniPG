-- api_v1/public/rpc/rpc_get_user_profile.sql
-- FUNCTION: api_v1_public.rpc_get_user_profile（17 号文档归位：迁移 024_admin_crud_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 024_admin_crud_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION api_v1_public.rpc_get_user_profile(p_user_id text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_row json; v_tenant text := current_tenant_id();
BEGIN
    -- 本人 / 超管 / 本租户成员（管理端查看）
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'user_id required' USING ERRCODE = '22023';
    END IF;
    IF p_user_id <> current_user_id() AND NOT is_super_admin()
       AND NOT EXISTS (SELECT 1 FROM user_tenants
                       WHERE user_id = p_user_id AND organization_id = v_tenant) THEN
        RAISE EXCEPTION 'permission denied' USING ERRCODE = '42501';
    END IF;
    SELECT COALESCE(row_to_json(p), '{}'::json) INTO v_row
    FROM user_profile p WHERE p.user_id = p_user_id;
    RETURN COALESCE(v_row, '{}'::json);
END $$;
GRANT EXECUTE ON FUNCTION api_v1_public.rpc_get_user_profile(text) TO authenticated;
