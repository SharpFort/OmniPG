-- db/api_v1/public/views/user_tenants.sql
-- 034: 由 api_v1_public.user_role 更名而来（消除与 public.user_role 表同名冲突）
-- 背景: T7 时代 user_role 视图 = user_tenants 投影（组织成员关系）；
--       024 新建 public.user_role 表（用户↔Logto 全局角色分配镜像）后同名不同物。
--       按 026 定稿规则「视图名 = 底层表名」，本视图正名为 user_tenants。
--       真正的用户-角色分配经 v_user_roles / v_role_users 暴露（024）。
-- 列 = 表列（对齐 user_tenants: organization_id/user_id/joined_at）

DROP VIEW IF EXISTS api_v1_public.user_tenants CASCADE;
CREATE OR REPLACE VIEW api_v1_public.user_tenants AS
SELECT
    ut.user_id,
    ut.organization_id,        -- Logto 组织 id（= 租户 id）
    ut.joined_at
FROM user_tenants ut;
COMMENT ON VIEW api_v1_public.user_tenants IS '用户-组织成员关系视图（Logto 镜像：user_tenants；034 由 user_role 更名，消除与 public.user_role 表同名冲突）';
