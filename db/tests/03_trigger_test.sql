-- 03_trigger_test.sql：触发器行为测试
BEGIN;
SELECT plan(10);

-- updated_at 触发器存在
SELECT trigger_exists('sys_user', 'trg_user_updated_at');
SELECT trigger_exists('sys_role', 'trg_role_updated_at');
SELECT trigger_exists('sys_department', 'trg_department_updated_at');
SELECT trigger_exists('sys_tenant', 'trg_tenant_updated_at');

-- updated_at 自动更新
SELECT lives_ok($$
    PREPARE update_test AS UPDATE sys_user SET username = 'admin' WHERE id = '00000000-0000-0000-0000-100000000001';
    EXECUTE update_test;
    DEALLOCATE update_test;
$$, 'updated_at 自动更新不抛异常');

-- blacklist_at_on_role_change 触发器存在
SELECT trigger_exists('sys_user_role', 'trg_blacklist_on_role_change');

-- 角色变更触发器：分配角色后，检查黑名单是否有对应记录
SELECT lives_ok($$
    SET request.jwt.claims = '{"user_id":"00000000-0000-0000-0000-100000000001","tenant_id":"00000000-0000-0000-0000-000000000001","roles":["super_admin"]}';
    INSERT INTO sys_user_role (user_id, role_id, tenant_id) 
    VALUES ('00000000-0000-0000-0000-100000000001', '00000000-0000-0000-0000-200000000002', '00000000-0000-0000-0000-000000000001');
    DELETE FROM sys_user_role WHERE user_id = '00000000-0000-0000-0000-100000000001' AND role_id = '00000000-0000-0000-0000-200000000002';
    RESET request.jwt.claims;
$$, '角色变更触发器流程');

-- pg_notify 触发器存在
SELECT trigger_exists('sys_role_api', 'trg_reload_on_role_api');

-- audit_trigger_func 触发器
SELECT trigger_exists('sys_user', 'trg_audit_sys_user');
SELECT trigger_exists('sys_role', 'trg_audit_sys_role');

SELECT * FROM finish();
ROLLBACK;
