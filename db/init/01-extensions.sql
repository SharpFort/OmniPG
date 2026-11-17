-- ==============================================================================
-- PostgreSQL 扩展安装脚本（幂等兜底；权威管理 = Pigsty pigsty.yml，2026-08-16 拍板）
--   Pigsty 已管理: pg_cron / pg_graphql（集群级安装，不在本文件）
--   已移除: pgaudit（当前未启用；启用路径 = Pigsty pg_libs 配 shared_preload_libraries
--            + 重启集群后 Pigsty 安装）、pgsodium（全项目零使用，2026-08-16 退役）
--   本文件仅保留 apply-src 依赖的最小集（IF NOT EXISTS 幂等，已装即跳过）
--   扩展 schema 政策（2026-11-11 拍板）：一律安装到 ext（app_owner 的
--   search_path = platform, ext），禁止落在 public。
--   注: pg_idkit / pg_net 声明 relocatable=false 且要求 superuser，
--       只能在创建时指定 SCHEMA（本脚本由超户执行），事后无法 ALTER SET SCHEMA。
-- ==============================================================================

-- 密码哈希：Argon2id（OWASP 首选，抗 GPU/ASIC）
CREATE EXTENSION IF NOT EXISTS "pg_pwhash" WITH SCHEMA ext;

-- 辅助加密函数（sha256 等，仅用于非密码场景）
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA ext;

-- 异步 HTTP 请求（webhook 回调、pg_notify 增强；函数位于扩展自带的 net schema）
CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA ext;

-- NanoID/UUIDv7/ULID 等 ID 生成（places.entity_id 8 位 no-look-alikes 小写表）
CREATE EXTENSION IF NOT EXISTS "pg_idkit" WITH SCHEMA ext;

-- 语句级执行统计（pigsty Grafana 慢查询面板依赖；需 shared_preload_libraries 已含
-- pg_stat_statements，由 Pigsty postgresql.conf 管理）
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA ext;

-- pigsty 监控用户（Grafana postgres 数据源）裸查 pg_stat_statements：
-- 其默认 search_path 不含 ext，需角色级 search_path + schema USAGE（2026-11-11 现场已设）：
--   ALTER ROLE dbuser_monitor SET search_path TO ext, public;
GRANT USAGE ON SCHEMA ext TO dbuser_monitor;

-- pgTAP 单元测试框架
CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA ext;

\echo '扩展安装完成：pg_pwhash, pgcrypto, pg_net, pg_idkit, pgtap（schema=ext）'
