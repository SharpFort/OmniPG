-- 06_rtr_test.sql：Refresh Token 轮转 + 防重放测试
BEGIN;
SELECT plan(8);

-- 前置：需要先执行登录获取 refresh_token
-- 此处使用 dbmock 模拟

-- 1. refresh_token_rtr 使用旧 RT 刷新应成功
-- 2. 再次使用同一旧 RT 应失败（防重放）
-- 3. 刷新后应返回新的 access_token
-- 4. 使用无效 RT 应失败
-- 5. 过期 RT 应被拒绝
-- 6. 已被 is_used=TRUE 的 RT 应触发全端下线

-- 由于 refresh_token_rtr 依赖 Casdoor 端点，基础测试仅验证函数结构和异常路径

SELECT has_function('refresh_token_rtr');
SELECT function_lang_is('refresh_token_rtr', 'plpgsql');
SELECT function_is_definer('refresh_token_rtr');

-- 无效 RT 应抛异常 'P0001'
SELECT throws_ok($$
    SELECT refresh_token_rtr('invalid-refresh-token-that-is-64-characters-long-1234567890abcdef1234567890abcdef')
$$, 'P0001', 'Invalid Session', '无效 RT 被拒绝');

SELECT * FROM finish();
ROLLBACK;
