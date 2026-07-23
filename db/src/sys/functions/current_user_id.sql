-- db/src/sys/functions/current_user_id.sql
-- 从 JWT 中提取当前用户 ID（STABLE 缓存优化）
-- 来源: 20260707000008_enable_rls_policies.sql

CREATE OR REPLACE FUNCTION current_user_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        current_setting('request.jwt.claims', true)::json->>'user_id',
        '00000000-0000-0000-0000-000000000000'
    )::uuid;
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_id() IS '从 JWT 中提取当前用户 ID（STABLE 缓存优化）';
