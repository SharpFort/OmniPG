-- db/api_v1/sys/rpc/rpc_approve_role_request.sql
-- 审批角色申请 RPC：包装 public.approve_role_request
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1_sys.approve_role_request(p_request_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.approve_role_request(p_request_id) $$;
COMMENT ON FUNCTION api_v1_sys.approve_role_request(uuid) IS '审批角色申请：委托 public.approve_role_request';
