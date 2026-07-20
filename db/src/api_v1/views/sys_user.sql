CREATE OR REPLACE VIEW api_v1.sys_user AS
SELECT id, username, tenant_id, dept_id, email, phone, is_active, created_at, updated_at
FROM public.sys_user;
