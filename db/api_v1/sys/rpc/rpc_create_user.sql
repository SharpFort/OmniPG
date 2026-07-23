-- db/api_v1/sys/rpc/rpc_create_user.sql
-- 创建用户 RPC：自动生成 Argon2id 密码哈希
-- 来源: 20260707000013_postgrest_api_v1.sql

CREATE OR REPLACE FUNCTION api_v1.create_user(
    p_username text,
    p_password text,
    p_tenant_id uuid,
    p_dept_id uuid DEFAULT NULL,
    p_email text DEFAULT NULL,
    p_phone text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    INSERT INTO public.sys_user (username, password_hash, tenant_id, dept_id, email, phone)
    VALUES (p_username, generate_user_password(p_password), p_tenant_id, p_dept_id, p_email, p_phone)
    RETURNING id INTO v_user_id;
    RETURN v_user_id;
END;
$$;
COMMENT ON FUNCTION api_v1.create_user(text, text, uuid, uuid, text, text) IS '创建用户：自动生成 Argon2id 密码哈希';
