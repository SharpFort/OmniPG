-- 077_revoke_logto_projection_writes.sql
-- 077（2026-11-20）：Logto 只读投影写权限收口（阶段 3 e2e 收尾）
--
-- 背景：api_v1/platform/privileges/zz_grant_all.sql:80 的
--   GRANT ALL ON ALL TABLES IN SCHEMA api_v1_platform TO super_admin
-- 使 Logto 只读投影视图对 super_admin 开放了 DML。N4（2026-08-11）只对 role_admin
-- 显式收权（users/role），super_admin 的兜底授权未覆盖。
-- 后果（e2e 15/34 时代因 TOKEN 缺失从未真实执行，回调修复后首次暴露）：
--   * POST /api/v1/platform/users → 权限层放行 → 执行层 55000（users 为 JOIN 视图
--     不可自动更新）→ PostgREST 返回 500，而非预期的 4xx —— e2e Users Readonly FAIL；
--   * POST role/tenants → 可自动更新，靠基表 RLS 42501 返回 403 —— 侥幸 PASS，
--     依赖 RLS 而非 ACL 的设计保证。
-- 终态：六个 Logto 侧投影（users/role/tenants/tenant_role/organizations/user_tenants）
--   对全部登录角色收回 DML；唯一写入口为 Logto 本体（public 表）与
--   SECURITY DEFINER 同步函数（webhook_logto/sync_login_log_write 等，不受影响）。
-- 幂等性：REVOKE 对不存在的授权是空操作，可安全重放；本迁移可回滚（down 恢复
--   super_admin 的 ALL 授权以还原 :80 语义）。
-- 关联：e2e-test.sh readonly_rejected 断言（批次2d）；ocr 阶段 3 验收项 Users Readonly。
-- migrate:up

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    api_v1_platform.users, api_v1_platform.role, api_v1_platform.tenants,
    api_v1_platform.tenant_role, api_v1_platform.organizations,
    api_v1_platform.user_tenants
    FROM super_admin;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    api_v1_platform.users, api_v1_platform.role, api_v1_platform.tenants,
    api_v1_platform.tenant_role, api_v1_platform.organizations,
    api_v1_platform.user_tenants
    FROM role_admin, role_editor, role_guest, tenant_admin;

-- migrate:down

GRANT ALL ON
    api_v1_platform.users, api_v1_platform.role, api_v1_platform.tenants,
    api_v1_platform.tenant_role, api_v1_platform.organizations,
    api_v1_platform.user_tenants
    TO super_admin;
