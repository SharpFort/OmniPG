-- db/api_v1/sys/views/sys_role
-- T7: 重建为 role 投影（Logto 全局角色目录），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_sys.role CASCADE;
CREATE OR REPLACE VIEW api_v1_sys.role AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text                          AS tenant_id,      -- Logto 角色为全局（组织角色在 organization_roles）
    NULL::text                          AS description,
    NOT r.is_default                    AS is_active,      -- 默认角色视为内置（活跃）
    r.created_at,
    r.updated_at,
    NULL::timestamptz                   AS deleted_at,
    NULL::text                          AS created_by,
    NULL::text                          AS updated_by,
    NULL::text                          AS deleted_by
FROM role r;
COMMENT ON VIEW api_v1_sys.role IS '角色表视图（Logto 镜像：role 投影，全局角色）';
