-- 073_audit_timeline_null_defaults.sql
-- 073（2026-08-30）：修复审计时间线 RPC 传 NULL 日期时恒返回空
-- 背景：get_audit_log_timeline 的 p_start_date/p_end_date 原默认值为
--   now()-7 天 / now()，但 PostgreSQL 显式传 NULL 不会触发参数默认值；
--   前端不传日期时发送的是 NULL → WHERE log_date >= NULL 恒假 → 时间线恒为空。
-- 内容：参数改 DEFAULT NULL + 函数体内 COALESCE 回退最近 7 天（语义不变）。
-- P0-5 归位（2026-11-02）：函数定义迁出迁移目录，终态归位
--   db/api_v1/platform/rpc/rpc_get_audit_log_timeline.sql（073 修复 + p_limit 限流版）。
--   §6.3 零容忍扫描要求迁移目录不含代码对象；且 apply-src 回放顺序中 migrations
--   在 privileges 之后——留在迁移内的 CREATE OR REPLACE 旧签名(timestamp,timestamp)
--   会在 rpc 文件 DROP 旧签名后将其复活（默认 ACL=PUBLIC EXECUTE，绕过
--   99_revoke_public 收口；裸回放连 migrate:down 段一并执行还会回退 073 修复语义，
--   且 PostgREST 双参调用会优先绑定到复活的旧签名）。
--   （已应用环境 dbmate 不重跑本迁移；apply-src 经 rpc 文件幂等重建，结果一致。）
-- migrate:up

SELECT 1;  -- no-op：代码对象已归位 db/api_v1（本迁移保留版本号占位）

-- migrate:down

SELECT 1;  -- no-op：函数生命周期由 db/api_v1 终态文件管理
