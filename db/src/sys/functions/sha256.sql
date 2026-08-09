-- db/src/sys/functions/sha256.sql
-- SHA256 哈希包装函数（仅用于非密码场景）
-- 来源: 20260707000005_create_auth_functions.sql

CREATE OR REPLACE FUNCTION public.sha256(data bytea) 
RETURNS text AS $$
    SELECT encode(digest(data, 'sha256'), 'hex');
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;
COMMENT ON FUNCTION public.sha256(bytea) IS 'SHA256 哈希包装函数，返回 hex 编码的 64 字符哈希值（仅用于非密码场景）；public. 限定——PG18 内置 sha256(bytea) 在 pg_catalog，无限定会解析到内置（返回 bytea 且属主 postgres 不可 REPLACE）';
