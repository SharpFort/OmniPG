-- db/src/platform/privileges/99_function_exec_acls.sql
-- 平台函数 EXECUTE 收口——终态断言（幂等，2026-11-19 安全加固批新增）
--
-- 背景：_init_schema.sql 的 `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA platform
-- TO authenticated / role_admin / role_editor / role_guest` 会随每次 apply-src 重放
-- （_init_schema.sql 按字典序先于 functions/ 执行）。functions/*.sql 内的逐文件
-- REVOKE 只在同一次完整重放中生效；为确保任意时点、任意重放顺序后的终态一致，
-- 本文件在 privileges/ 阶段（functions 之后）重新断言以下 SECURITY DEFINER 写函数的收口：
--   * log_operate / write_audit_log：直写 append-only 审计表（audit_log），
--     仅允许 owner 经 DEFINER 函数链内部调用——任何 API 登录角色直接调用即伪造审计。
--   * sync_login_log_write：webhook 专用写入口，仅 owner。
--   * import_geolite2_city：具备 TRUNCATE 全表权能，仅运行时超管 super_admin。
-- 纯 claims 读取 helper（current_user_id / current_*_tenant_id / is_super_admin 等）
-- 保持 PUBLIC EXECUTE——RLS 谓词要求任意角色可调用。

REVOKE EXECUTE ON FUNCTION platform.log_operate(text, text, text, text, text, jsonb)
    FROM PUBLIC, authenticated, role_guest, role_editor, role_admin, tenant_admin;
REVOKE EXECUTE ON FUNCTION platform.write_audit_log(text, text, jsonb, jsonb, text, text)
    FROM PUBLIC, authenticated, role_guest, role_editor, role_admin, tenant_admin;
REVOKE EXECUTE ON FUNCTION platform.sync_login_log_write(jsonb)
    FROM PUBLIC, authenticated, role_guest, role_editor, role_admin, tenant_admin;

REVOKE EXECUTE ON FUNCTION platform.import_geolite2_city()
    FROM PUBLIC, authenticated, role_guest, role_editor, role_admin, tenant_admin;
GRANT EXECUTE ON FUNCTION platform.import_geolite2_city() TO super_admin;
