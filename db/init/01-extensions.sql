-- ==============================================================================
-- PostgreSQL 扩展安装脚本（幂等兜底；权威管理 = Pigsty pigsty.yml，2026-08-16 拍板）
--   Pigsty 已管理: pg_cron / pg_graphql（集群级安装，不在本文件）
--   已移除: pgaudit（当前未启用；启用路径 = Pigsty pg_libs 配 shared_preload_libraries
--            + 重启集群后 Pigsty 安装）、pgsodium（全项目零使用，2026-08-16 退役）
--   本文件仅保留 apply-src 依赖的最小集（IF NOT EXISTS 幂等，已装即跳过）
-- ==============================================================================

-- 密码哈希：Argon2id（OWASP 首选，抗 GPU/ASIC）
CREATE EXTENSION IF NOT EXISTS "pg_pwhash";

-- 辅助加密函数（sha256 等，仅用于非密码场景）
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 异步 HTTP 请求（webhook 回调、pg_notify 增强）
CREATE EXTENSION IF NOT EXISTS "pg_net";

-- pgTAP 单元测试框架
CREATE EXTENSION IF NOT EXISTS "pgtap";

\echo '扩展安装完成：pg_pwhash, pgcrypto, pg_net, pgtap'
