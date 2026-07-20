-- ==============================================================================
-- PostgreSQL 扩展安装脚本（容器首次启动自动执行）
-- 此脚本挂载到 /docker-entrypoint-initdb.d/ 目录，PG 容器启动时自动执行
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";        -- 密码加密、gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";       -- UUID 生成（备用）
CREATE EXTENSION IF NOT EXISTS "pgaudit";         -- SQL 审计日志
CREATE EXTENSION IF NOT EXISTS "pgsodium";        -- 透明列加密
CREATE EXTENSION IF NOT EXISTS "pg_net";          -- 异步 HTTP 请求、LISTEN/NOTIFY
CREATE EXTENSION IF NOT EXISTS "pgtap";           -- pgTAP 单元测试

\echo '扩展安装完成：pgcrypto, uuid-ossp, pgaudit, pgsodium, pg_net, pgtap'
