-- ==============================================================================
-- 初始 Schema 和角色创建（容器首次启动自动执行）
-- ==============================================================================

-- 系统管理 API Schema（027 改名链兼容）
--   api_v1_sys  : 历史迁移引用承载（027 迁移 RENAME → api_v1_public 或清理残留）
--   api_v1_public: 系统管理 API 暴露层（027 定稿名；视图名 = 底层表名）
CREATE SCHEMA IF NOT EXISTS api_v1_sys;
COMMENT ON SCHEMA api_v1_sys IS '系统管理 API Schema（兼容历史迁移引用；027 迁移统一收敛）';
CREATE SCHEMA IF NOT EXISTS api_v1_public;
COMMENT ON SCHEMA api_v1_public IS '系统管理 API 暴露层（027 定稿：视图名=底层表名；原 api_v1_sys）';

CREATE SCHEMA IF NOT EXISTS net;
-- net schema 注释不在此处维护：pg_net 扩展宿主 schema（owner=postgres），
--   app_owner 执行 COMMENT 必炸（must be owner）；注释由扩展安装方（superuser）负责

-- ==============================================================================
-- 角色与成员关系：由 Pigsty 管理（2026-08-16 拍板，安全第一/最小权限分层）
--   角色创建与角色间 GRANT 属集群级操作，需 ADMIN OPTION（仅角色创建管理员持有），
--   与 PostgREST 官方模型一致（管理员创建 authenticator/web_anon/authenticated）。
--   Pigsty 配置参考（pigsty.yml → pg_users）：
--     pg_users:
--       - { name: web_anon,          nologin: true }
--       - { name: authenticated,     nologin: true }
--       - { name: authenticator,     login: true, password: '<改>', noinherit: true,
--           roles: [web_anon, authenticated, super_admin, role_admin, role_editor,
--                   role_guest, role_super_admin, tenant_admin] }
--       - { name: super_admin,       nologin: true }
--       - { name: role_admin,        nologin: true }
--       - { name: role_editor,       nologin: true }
--       - { name: role_guest,        nologin: true }
--       - { name: role_super_admin,  nologin: true, roles: [super_admin] }
--       - { name: tenant_admin,      nologin: true, roles: [role_admin] }
-- ==============================================================================

-- Schema 使用权（api_v1 已随 027 收敛为 api_v1_public）
GRANT USAGE ON SCHEMA api_v1_public TO web_anon;
GRANT USAGE ON SCHEMA api_v1_public TO authenticated;
GRANT USAGE ON SCHEMA api_v1_public TO authenticator;

-- web_anon 默认无任何表权限（安全第一）
-- authenticated 的权限由 db/api_v1/public/privileges/zz_grant_all.sql 与
--   db/src/public/privileges/rls_policies.sql 显式授予（RLS 为安全边界）

-- pg_net 权限收紧（2026-08-16 拍板）：pg_net 可发任意外网 HTTP 请求，
--   直接授 EXECUTE 给 authenticated = SSRF 后门；调用一律经 SECURITY DEFINER 封装函数
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA net FROM authenticated;
REVOKE USAGE ON SCHEMA net FROM authenticated;

\echo 'Schema 和角色创建完成'

-- ==============================================================================
-- T7: 原 api_v1.check_token_blacklist 包装函数（PGRST_DB_PRE_REQUEST）已退役
--     D12: 会话/吊销交 Logto；PGRST_DB_PRE_REQUEST 已清空
-- ==============================================================================

