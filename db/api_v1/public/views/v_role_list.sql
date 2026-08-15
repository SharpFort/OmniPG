-- db/api_v1/public/views/v_role_list.sql
-- T7: 重建为 role 投影 + 绑定计数（Logto 语义），与 013 迁移一致
-- 034: users_count 由恒 0 改为真实计数（024 建 user_role 分配镜像表后未同步；
--      仅超管统计准确——user_role 表 RLS = 超管 OR 本人，租户管理员只见本人行）
-- 055: api_count 口径改单表化——角色绑定的带端点按钮行数（iam_role_api 已删除）
-- 061: 镜像表无 updated_at——映射 logto_updated_at（同步水位）
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
    r.logto_updated_at AS updated_at,   -- 061: 同步水位
    NULL::timestamptz AS deleted_at,
    '全局'::character varying AS tenant_name,
    (SELECT count(*) FROM iam_role_menu rm JOIN iam_menu m ON m.id = rm.menu_id
     WHERE rm.role_code = r.role_code AND m.api_url IS NOT NULL) AS api_count,
    (SELECT count(*) FROM iam_role_menu rm WHERE rm.role_code = r.role_code) AS menu_count,
    (SELECT count(*) FROM user_role ur WHERE ur.role_code = r.role_code) AS users_count  -- 034: 真实计数
FROM role r;
COMMENT ON VIEW api_v1_public.v_role_list IS '角色列表视图（Logto 镜像：role + 绑定计数；034 users_count 真实计数；055 api_count 口径=带端点按钮绑定数；061 updated_at=同步水位）';
