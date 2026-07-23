-- db/src/sys/functions/sha256.sql
-- SHA256 哈希包装函数（仅用于非密码场景）
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION sha256(data bytea) 
RETURNS text AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;
COMMENT ON FUNCTION sha256(bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值（仅用于非密码场景）';
