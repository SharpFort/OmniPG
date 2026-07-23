-- db/api_v1/sys/views/sys_user_role_request
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE VIEW api_v1_sys.sys_user_role_request AS
SELECT id, user_id, role_id, tenant_id, status, applicant_id, approver_id, created_at, approved_at, updated_at
FROM public.sys_user_role_request;
COMMENT ON VIEW api_v1_sys.sys_user_role_request IS '角色申请审批视图'；
