-- db/api_v1/sys/rpc/rpc_update_role_permissions.sql
-- 批量更新角色权限 RPC（API 和菜单）
-- 来源: 20260707000015_system_management_api.sql

CREATE OR REPLACE FUNCTION api_v1_sys.update_role_permissions(
    p_role_id uuid,
    p_api_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_menu_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.sys_role WHERE id = p_role_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'Role not found' USING ERRCODE = 'P0001';
    END IF;
    
    IF array_length(p_api_ids, 1) > 0 THEN
        DELETE FROM public.sys_role_api WHERE role_id = p_role_id;
        INSERT INTO public.sys_role_api (role_id, api_id)
        SELECT p_role_id, unnest(p_api_ids)
        ON CONFLICT DO NOTHING;
    END IF;
    
    IF array_length(p_menu_ids, 1) > 0 THEN
        DELETE FROM public.sys_role_menu WHERE role_id = p_role_id;
        INSERT INTO public.sys_role_menu (role_id, menu_id)
        SELECT p_role_id, unnest(p_menu_ids)
        ON CONFLICT DO NOTHING;
    END IF;
    
    RETURN TRUE;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.update_role_permissions(uuid, uuid[], uuid[]) IS '批量更新角色权限（API 和菜单）';
GRANT EXECUTE ON FUNCTION api_v1_sys.update_role_permissions(uuid, uuid[], uuid[]) TO authenticated;
