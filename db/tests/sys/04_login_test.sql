-- 04_login_test.sql：登录流程测试
BEGIN;
SELECT plan(12);

-- 设置 superuser 测试身份
SET request.jwt.claims = '{"user_id":"00000000-0000-0000-0000-100000000001","tenant_id":"00000000-0000-0000-0000-000000000001","roles":["super_admin"]}';

-- 1. 正确登录应返回 JSON
SELECT lives_ok($$
    SELECT user_login_sso('admin', 'admin123')
$$, '正确密码登录不抛异常');

-- 2. 错误密码应抛异常
SELECT throws_ok($$
    SELECT user_login_sso('admin', 'wrong_password')
$$, 'P0001', 'Invalid Credentials', '错误密码抛 P0001');

-- 3. 不存在的用户应抛异常
SELECT throws_ok($$
    SELECT user_login_sso('nonexistent_user', 'any_password')
$$, 'P0001', 'Invalid Credentials', '不存在的用户抛 P0001');

-- 4. 软删用户应无法登录
-- （需要先创建并软删除测试用户，此处省略）

-- 5. user_login_sso 函数 SECURITY DEFINER
SELECT function_is_definer('user_login_sso');

-- 6. refresh_token_rtr 函数 SECURITY DEFINER
SELECT function_is_definer('refresh_token_rtr');

-- 7. check_token_blacklist 函数存在
SELECT has_function('check_token_blacklist');

-- 8. pg_pwhash 生成哈希测试
SELECT lives_ok($$
    SELECT pwhash_crypt('test_password', pwhash_gen_salt('argon2id'))
$$, 'Argon2id 哈希生成不抛异常');

-- 9. pg_pwhash 验证测试
SELECT lives_ok($$
    DECLARE
        v_hash text;
    BEGIN
        v_hash := pwhash_crypt('test_password', pwhash_gen_salt('argon2id'));
        IF pwhash_crypt('test_password', v_hash) != v_hash THEN
            RAISE EXCEPTION 'Password verification failed';
        END IF;
    END;
$$, 'Argon2id 密码验证通过');

RESET request.jwt.claims;

SELECT * FROM finish();
ROLLBACK;
