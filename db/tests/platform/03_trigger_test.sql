-- 03_trigger_test.sql：触发器行为测试（T9: trg_audit_department 新名，与 028 对齐）
BEGIN;
SELECT plan(4);

-- 审计触发器存在（department；028 已从 trg_audit_sys_department 更名）
SELECT has_trigger('department', 'trg_audit_department');

-- 审计触发器函数存在
SELECT has_function('audit_trigger_func');
SELECT has_function('update_updated_at');

-- updated_at 自动更新不抛异常（department 表）
SELECT lives_ok($$
    UPDATE department SET sort_order = sort_order WHERE id = '00000000-0000-0000-0000-000000000000';
$$, 'department updated_at 更新不抛异常');

SELECT * FROM finish();
ROLLBACK;
