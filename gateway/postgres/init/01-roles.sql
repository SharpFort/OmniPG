-- =============================================================================
-- docker pgsql 首次初始化: 创建 PostgREST 所需角色
-- 仅当数据卷为空（首次启动）时由 docker-entrypoint-initdb.d 自动执行
-- 已存在的卷需手动执行本脚本（docker exec pgsql psql -U app_owner -d app_db -f ...）
-- 角色定义与 infra/pigsty.yml 的 pg_users 保持一致
-- =============================================================================
CREATE ROLE authenticator LOGIN PASSWORD 'authenticator_dev_pass' INHERIT;
CREATE ROLE web_anon NOLOGIN;
GRANT web_anon TO authenticator;
