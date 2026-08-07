-- db/api_v1/sys/views/sys_role_list
-- T7: 重建为 role 投影 + 绑定计数（Logto 语义），与 013 迁移一致
-- 034: users_count 由恒 0 改为真实计数（024 建 user_role 分配镜像表后未同步；
--      仅超管统计准确——user_role 表 RLS = 超管 OR 本人，租户管理员只见本人行）
-- 来源: 20260707000013_postgrest_api_v1.sql（T7 改造）

DROP VIEW IF EXISTS api_v1_public.v_role_list CASCADE;
CREATE OR REPLACE VIEW api_v1_public.v_role_list AS
SELECT
    r.id,
    r.role_code,
    COALESCE(r.name, r.role_code) AS role_name,
    NULL::text AS tenant_id,
    NULL::text AS description,
    true::boolean AS is_active,         -- 034: 同 role 视图语义
    r.created_at,
    r.updated_at,
    NULL::timestamptz AS deleted_at,
    '全局'::character varying AS tenant_name,
    (SELECT count(*) FROM iam_role_api ra WHERE ra.role_code = r.role_code) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_code = r.role_code) AS menu_count,
    (SELECT count(*) FROM user_role ur WHERE ur.role_code = r.role_code) AS users_count  -- 034: 真实计数
FROM role r;
COMMENT ON VIEW api_v1_public.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数；034 users_count 改真实计数）';
