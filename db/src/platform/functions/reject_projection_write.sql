-- db/src/platform/functions/reject_projection_write.sql
-- Logto 只读投影统一写拒绝触发器函数（2026-11-20，阶段 3 e2e 收尾）
--
-- 背景：api_v1_platform 的 Logto 投影视图（users/role/tenants/tenant_role/
--   organizations/user_tenants）经 PostgREST 写入时：
--   * JOIN 视图（users）在 PG 改写阶段报 55000——改写早于 ACL 检查，
--     即使 077 已收回全部登录角色的 INSERT，错误仍映射为 500 而非 4xx；
--   * 单表可更新投影（role 等）当前靠基表 RLS 兜底返回 403，属侥幸而非设计保证
--     （zz_grant_all.sql:80 的 ALL TABLES 兜底授权回归时将静默变为可写）。
-- 方案：INSTEAD OF 触发器统一 RAISE ERRCODE '42501'（insufficient_privilege），
--   PostgREST 将 42501 映射为 403——任何角色（含 owner）写投影一律在 DB 层
--   显式拒绝，与 077 的 ACL 收权构成双层防线。
-- 触发器挂载：db/api_v1/platform/views/zz_readonly_guards.sql（六视图 × 三事件）。

CREATE OR REPLACE FUNCTION platform.reject_projection_write()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'view %.% is a read-only Logto projection: direct writes are not permitted',
        TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = '42501',
              HINT = 'Logto 侧数据唯一写入口：Logto Admin Console 与 SECURITY DEFINER 同步函数';
END;
$$;

COMMENT ON FUNCTION platform.reject_projection_write() IS
'Logto 只读投影统一写拒绝触发器（42501 → PostgREST 403）；挂载点见 db/api_v1/platform/views/zz_readonly_guards.sql（阶段3 e2e Users Readonly 收尾）';
