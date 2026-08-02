-- db/src/sys/functions/current_user_id.sql
-- 从 JWT 中提取当前用户 ID（Phase 1: 改读 Casdoor OIDC 标准 claim `sub`）
-- 来源: 20260707000008_enable_rls_policies.sql → Phase 1 适配 Casdoor JWT
-- Casdoor JWT: sub = 用户 UUID（与 casdoor_user_mirror.id 一致，D4）

CREATE OR REPLACE FUNCTION current_user_id() 
RETURNS uuid AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid,
        NULLIF(current_setting('request.jwt.claims', true)::json->>'id', '')::uuid,
        '00000000-0000-0000-0000-000000000000'
    );
$$ LANGUAGE sql STABLE PARALLEL SAFE;
COMMENT ON FUNCTION current_user_id() IS '从 JWT 中提取当前用户 ID（Casdoor sub claim，Phase 1 适配）';
