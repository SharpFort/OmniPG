-- db/api_v1/sys/views/v_online_users.sql
-- 在线用户视图（活跃会话）
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE VIEW api_v1.v_online_users AS
SELECT 
    s.id,
    s.user_id,
    s.tenant_id,
    s.active_jti,
    s.client_ip,
    s.user_agent,
    s.created_at AS session_created_at,
    s.expired_at,
    u.username,
    u.email,
    t.tenant_name
FROM public.sys_user_session s
JOIN public.sys_user u ON s.user_id = u.id
LEFT JOIN public.sys_tenant t ON s.tenant_id = t.id
WHERE s.is_used = FALSE
  AND s.expired_at > now()
  AND u.deleted_at IS NULL;
COMMENT ON VIEW api_v1.v_online_users IS '在线用户视图（活跃会话）';
