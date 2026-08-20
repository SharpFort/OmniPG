-- src/public/views/sys_user.sql
-- VIEW: public.sys_user —— 兼容视图（保留历史命名，非 sys 模块/非物理表）
--   数据源 = public.users（Logto 镜像）+ public.user_profile（业务档案）
--   对外请用 api_v1_public.users；本视图仅供历史查询兼容
-- 17 号文档归位：迁移 012_sys_user_profile_logto.sql 删定义段，本文件为唯一权威
-- 回放终态: 012_sys_user_profile_logto.sql；幂等写法（§9 模板）
-- 061（2026-08-15）: 镜像表清理后列集保持稳定——updated_at 映射 logto_updated_at（同步水位），
--   deleted_at/_by 恒 NULL（镜像表无软删/无 _by，兼容旧查询）

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
    u.logto_updated_at AS updated_at,         -- 061: 映射同步水位
    NULL::timestamptz AS deleted_at,          -- 061: 镜像表无软删，恒 NULL
    NULL::text AS created_by,                 -- 061: 镜像表无 _by，恒 NULL
    NULL::text AS updated_by,
    NULL::text AS deleted_by
FROM users u
LEFT JOIN user_profile p ON p.user_id = u.id;  -- 014 RENAME sys_user_profile→user_profile（归位修正）
