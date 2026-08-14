-- src/public/views/sys_user.sql
-- VIEW: public.sys_user（17 号文档归位：迁移 012_sys_user_profile_logto.sql 删定义段，本文件为唯一权威）
-- 回放终态: 012_sys_user_profile_logto.sql；幂等写法（§9 模板）

CREATE OR REPLACE VIEW public.sys_user
WITH (security_invoker = true) AS
SELECT
    u.id,
    u.username,
    NULL::text AS password_hash,              -- 密码由 Logto 管理，不再暴露
    p.tenant_id,
    p.dept_id,
    u.primary_email  AS email,
    u.primary_phone  AS phone,
    NOT u.is_suspended AS is_active,          -- D17: is_active = NOT isSuspended
    u.created_at,
    u.updated_at,
    u.deleted_at,
    u.created_by,
    u.updated_by,
    u.deleted_by
FROM users u
LEFT JOIN user_profile p ON p.user_id = u.id;  -- 014 RENAME sys_user_profile→user_profile（归位修正）
