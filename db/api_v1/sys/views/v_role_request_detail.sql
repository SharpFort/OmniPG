-- db/api_v1/sys/views/v_role_request_detail.sql
-- 角色申请审批详情视图
-- 来源: 20260707000016_relationship_management.sql

CREATE OR REPLACE VIEW api_v1_sys.v_role_request_detail AS
SELECT 
    rq.id,
    rq.user_id,
    u.username,
    u.email,
    rq.role_id,
    r.role_code,
    r.role_name,
    rq.tenant_id,
    t.tenant_name,
    rq.status,
    rq.applicant_id,
    ua.username AS applicant_name,
    rq.approver_id,
    uapp.username AS approver_name,
    rq.created_at,
    rq.approved_at,
    rq.updated_at
FROM public.sys_user_role_request rq
JOIN public.sys_user u ON rq.user_id = u.id
JOIN public.sys_role r ON rq.role_id = r.id
LEFT JOIN public.sys_tenant t ON rq.tenant_id = t.id
LEFT JOIN public.sys_user ua ON rq.applicant_id = ua.id
LEFT JOIN public.sys_user uapp ON rq.approver_id = uapp.id;
COMMENT ON VIEW api_v1_sys.v_role_request_detail IS '角色申请审批详情视图';
