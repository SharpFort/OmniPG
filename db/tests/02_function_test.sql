-- 02_function_test.sql：函数行为测试
BEGIN;
SELECT plan(14);

-- sha256 函数测试
SELECT function_lang_is('sha256', 'sql');
SELECT is(sha256('hello'::bytea), encode(digest('hello', 'sha256'), 'hex'), 'sha256 正确计算');

-- current_user_id 函数（无 JWT 时应返回全零 UUID）
SELECT lives_ok('SELECT current_user_id()', 'current_user_id 不抛异常');
SELECT is(current_tenant_id(), NULL, '无 JWT 时 tenant_id 为 NULL');

-- cleanup_expired_tokens 函数
SELECT function_lang_is('cleanup_expired_tokens', 'plpgsql');
SELECT lives_ok('SELECT cleanup_expired_tokens()', 'cleanup 函数可调用');

-- update_updated_at 函数存在
SELECT has_function('update_updated_at');
SELECT function_lang_is('update_updated_at', 'plpgsql');

-- audit_trigger_func 函数存在
SELECT has_function('audit_trigger_func');

-- is_super_admin 函数
SELECT has_function('is_super_admin');
SELECT function_lang_is('is_super_admin', 'sql');

-- pg_pwhash 函数
SELECT has_function('pwhash_crypt');
SELECT has_function('pwhash_gen_salt');

SELECT * FROM finish();
ROLLBACK;
