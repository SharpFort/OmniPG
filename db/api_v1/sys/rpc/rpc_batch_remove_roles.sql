-- db/api_v1/sys/rpc/rpc_batch_remove_roles.sql
-- 批量移除用户角色 RPC
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE FUNCTION api_v1_sys.batch_remove_roles(
    p_user_id uuid,
    p_role_ids uuid[]
)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH deleted AS (
        DELETE FROM public.sys_user_role 
        WHERE user_id = p_user_id AND role_id = ANY(p_role_ids)
        RETURNING role_id
    )
    SELECT json_build_object('removed', COUNT(*)::int) FROM deleted;
$$;
COMMENT ON FUNCTION api_v1_sys.batch_remove_roles(uuid, uuid[]) IS '批量移除用户角色';
GRANT EXECUTE ON FUNCTION api_v1_sys.batch_remove_roles(uuid, uuid[]) TO authenticated;
