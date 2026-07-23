-- db/src/sys/functions/is_super_admin.sql
-- 检查当前用户是否为超级管理员
-- 来源: 20260707000008_enable_rls_policies.sql

CREATE OR REPLACE FUNCTION is_super_admin()
RETURNS boolean AS $$
    SELECT current_setting('request.jwt.claims', true)::json->'roles' ? 'super_admin';
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION is_super_admin() IS '检查当前用户是否为超级管理员';
