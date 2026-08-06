-- db/api_v1/sys/views/v_role_list
-- T7: 重建为 role 投影 + 绑定计数（Logto 语义），与 013 迁移一致
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_public.v_role_list CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_list AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    NOT r.is_default AS is_active,
    r.created_at,
    r.updated_at,
    NULL::timestamptz AS deleted_at,
    '全局'::character varying AS tenant_name,
    (SELECT count(*) FROM iam_role_api ra WHERE ra.role_code = r.role_code) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_code = r.role_code) AS menu_count,
    0::bigint AS users_count            -- Logto 全局角色无直接 user 绑定镜像；成员关系见 sys_user_role
FROM role r;
COMMENT ON VIEW api_v1_public.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数）';
