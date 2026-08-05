-- db/src/sys/functions/current_user_id.sql
-- 当前用户 ID（Logto JWT: sub = 用户 id（21 位 nanoid），T7 重写）
-- 来源: 20260707000008_enable_rls_policies.sql → T7 适配

CREATE OR REPLACE FUNCTION current_user_id()
RETURNS text AS $$
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'sub', '')
$$ LANGUAGE sql STABLE PARALLEL SAFE
SECURITY DEFINER
SET search_path = public, pg_temp;
COMMENT ON FUNCTION current_user_id() IS '当前用户 ID（Logto JWT sub claim，text）';
