-- db/api_v1/sys/views/sys_user
-- T7: public.sys_user 兼容视图投影（Logto 镜像：users + user_profile）
-- 来源: 20260707000013_postgrest_api_v1.sql → T7 适配

CREATE OR REPLACE VIEW api_v1_sys.sys_user AS
SELECT id, username, email, phone, tenant_id, dept_id, is_active,
       created_at, updated_at, deleted_at, created_by, updated_by, deleted_by,
       password_hash
FROM public.sys_user;
COMMENT ON VIEW api_v1_sys.sys_user IS '用户表视图（password_hash 仅通过 RPC 访问）';
