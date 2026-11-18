-- db/api_v1/platform/rpc/rpc_ensure_user.sql
-- D25/D27: 登录 JIT 仅兜底业务档案（user_profile），组织归属取 claims organization_id；
--          tenant_id 由列默认值 'default' 填充（后续可由 Logto tenant_id claim 接管）。

CREATE OR REPLACE FUNCTION api_v1_platform.ensure_user()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_claims     jsonb := current_setting('request.jwt.claims', true)::jsonb;
    v_sub        text;
    v_org        text;
BEGIN
    v_sub := NULLIF(v_claims->>'sub', '');
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'Unauthorized: missing sub claim' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM platform.users WHERE id = v_sub) THEN
        RAISE EXCEPTION 'User not found in Logto' USING ERRCODE = 'P0001';
    END IF;
    v_org := NULLIF(v_claims->>'organization_id', '');
    IF v_org IS NOT NULL THEN
        INSERT INTO user_profile (user_id, organization_id, deleted_at)
        VALUES (v_sub, v_org, NULL)
        ON CONFLICT (user_id) DO NOTHING;
    END IF;
    RETURN v_sub;
END;
$$;
COMMENT ON FUNCTION api_v1_platform.ensure_user() IS '登录 JIT 兜底建档（D27：organization_id 取 claims organization_id；tenant_id 默认 default）';
GRANT EXECUTE ON FUNCTION api_v1_platform.ensure_user() TO authenticated;
