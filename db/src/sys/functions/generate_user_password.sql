-- db/src/sys/functions/generate_user_password.sql
-- 使用 Argon2id 算法生成密码哈希
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION generate_user_password(p_password text)
RETURNS text AS $$
    SELECT pwhash_crypt(p_password, pwhash_gen_salt('argon2id'));
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION generate_user_password(text) IS '使用 Argon2id 算法生成密码哈希。用于创建用户时自动生成 password_hash';
