-- =============================================================================
-- 025_admin_sync_tenant_rpc.sql — 租户管理 RPC（05.2 §六 P1 收尾）
-- =============================================================================
-- 背景: 2026-08-04 P1 落地（024 后）
--   rpc_list_tenants / rpc_list_tenant_members（管理端租户管理页）
--   ⚠️ 035 修订: rpc_sync_user_roles 已删除（Logto 无"用户-角色绑定"webhook 事件，
--     无法推送；JIT 覆盖并入 ensure_user——登录时 JWT claims 即 Logto 权威快照；
--     user_role 表由 ensure_user 维护，035 迁移 DROP IF EXISTS 兜底已执行环境）
-- 安全模型:
--   - 租户 RPC 需 sys:tenant:list / sys:tenant-member:list（035 补绑 tenant_admin）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 rpc_list_tenants — 租户列表（分页 + 成员数）
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §2 rpc_list_tenant_members — 租户成员列表
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- §3 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_fn int; v_tbl int;
BEGIN
    -- 环境自适应（17 号文档）：api_v1_sys 已于 027 改名 api_v1_public，
    -- 重放第二遍 schema 不存在——用 schema 名 join 查询（不存在返回 0）
    SELECT count(*) INTO v_fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api_v1_sys'
        AND p.proname IN ('rpc_list_tenants','rpc_list_tenant_members');
    SELECT count(*) INTO v_tbl FROM pg_tables
      WHERE schemaname='public' AND tablename='user_role';
    RAISE NOTICE '025: 函数=%（期望2） user_role表=%（期望1）', v_fn, v_tbl;
END $$;
