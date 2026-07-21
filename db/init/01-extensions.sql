-- ==============================================================================
-- PostgreSQL 扩展安装脚本（容器首次启动自动执行）
-- 此脚本挂载到 /docker-entrypoint-initdb.d/ 目录，PG 容器启动时自动执行
-- ==============================================================================

-- 密码哈希：Argon2id（OWASP 首选，抗 GPU/ASIC）
CREATE EXTENSION IF NOT EXISTS "pg_pwhash";

-- 辅助加密函数（sha256 等，仅用于非密码场景）
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- SQL 审计日志（记录所有 DDL/DML）
CREATE EXTENSION IF NOT EXISTS "pgaudit";

-- 透明列加密（敏感字段加密）
CREATE EXTENSION IF NOT EXISTS "pgsodium";

-- 异步 HTTP 请求（Casdoor 集成、pg_notify 增强）
CREATE EXTENSION IF NOT EXISTS "pg_net";

-- pgTAP 单元测试框架
CREATE EXTENSION IF NOT EXISTS "pgtap";

\echo '扩展安装完成：pg_pwhash, pgcrypto, pgaudit, pgsodium, pg_net, pgtap'
