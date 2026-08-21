-- db/api_v1/platform/views/sys_role
-- T7: 重建为 role 投影（Logto 全局角色目录），与 013 迁移一致
-- 034: is_active 语义修复——Logto 角色无「停用」状态（角色删除即移除），
--       原 NOT r.is_default 映射与注释意图相反（默认角色被标为停用），恒 true 兼容前端过滤
-- 061: 镜像表无 updated_at——映射 logto_updated_at（同步水位）
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_platform.role CASCADE;
CREATE OR REPLACE VIEW api_v1_platform.role AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text                          AS tenant_id,      -- Logto 角色为全局（组织角色在 organization_roles）
    NULL::text                          AS description,
    true::boolean                       AS is_active,      -- 034: Logto 角色目录无停用状态，恒 true
    r.created_at,
    r.logto_updated_at AS updated_at,                      -- 061: 同步水位
    NULL::timestamptz                   AS deleted_at,
    NULL::text                          AS created_by,
    NULL::text                          AS updated_by,
    NULL::text                          AS deleted_by
FROM role r;
COMMENT ON VIEW api_v1_platform.role IS '角色表视图（Logto 镜像：role 投影，全局角色；is_active 恒 true——Logto 无角色停用概念，034；061 updated_at=同步水位）';
