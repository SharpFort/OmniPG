-- db/api_v1/sys/views/sys_user_role
-- T7: 重建为 user_tenants 投影（Logto 组织成员关系），与 013 迁移一致
-- Logto 语义：用户-组织成员 = user_tenants；组织角色在 Logto organization_roles
-- （app_db 未镜像角色绑定，成员关系即授权面）
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_sys.sys_user_role CASCADE;
CREATE VIEW api_v1_sys.sys_user_role AS
SELECT
    ut.user_id,
    ut.organization_id AS role_id,      -- 兼容列名：组织即"角色域"
    ut.organization_id AS tenant_id,
    ut.joined_at AS created_at,
    NULL::text AS created_by
FROM user_tenants ut;
COMMENT ON VIEW api_v1_sys.sys_user_role IS '用户-角色关联视图（Logto 镜像：user_tenants 成员关系投影）';
