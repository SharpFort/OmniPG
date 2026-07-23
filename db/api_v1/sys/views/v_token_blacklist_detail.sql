-- db/api_v1/sys/views/v_token_blacklist_detail.sql
-- Token 黑名单详情视图
-- 来源: 20260707000017_audit_session_monitoring.sql

CREATE OR REPLACE VIEW api_v1_sys.v_token_blacklist_detail AS
SELECT 
    b.jti,
    b.blacklisted_at,
    b.expired_at,
    b.reason,
    b.user_id,
    u.username,
    CASE 
        WHEN b.expired_at > now() THEN 'expired'
        ELSE 'active'
    END AS token_status
FROM public.sys_token_blacklist b
LEFT JOIN public.sys_user u ON b.user_id = u.id
ORDER BY b.blacklisted_at DESC;
COMMENT ON VIEW api_v1_sys.v_token_blacklist_detail IS 'Token 黑名单详情视图';
