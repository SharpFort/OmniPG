-- 076_geolite2_gist_concurrent.sql
-- 076（2026-11-19）：geo_locate() 的 GiST 索引（批次 2c · 性能审查 P-2a）
--
-- 背景：geo_locate() 使用 `g.network >>= v_cidr`（cidr 包含操作符），btree 无法服务——
-- 此前的主键 btree(network) 对包含查询恒全表扫描。
-- opclass 说明（批次2c 验收修正）：cidr 的 GiST **默认** opclass（gist_cidr_ops）
-- 来自 btree_gist 扩展且被上游认定存在边界缺陷（Tom Lane, pgsql-hackers 2025-08）；
-- 核心自 9.4 起内置 `inet_ops`（支持 << <<= >> >>= = <> < <= > >= &&），
-- 但**非默认**、必须显式指定。MaxMind GeoLite2 查询的标准做法即：
--   CREATE INDEX ... USING gist (network inet_ops);
-- 故本迁移不依赖任何扩展。
-- 注意：
--   * CONCURRENTLY 不可在事务内执行，故本迁移 transaction:false；
--     dbmate 需支持该模式的语句拆分（PR #286 起，建议 ≥1.16）；
--     老版本若报 "syntax error at near transaction"（amacneil/dbmate#455）需升级后重放。
--   * CONCURRENTLY 失败（超时/断连）会遗留 invalid 索引且 IF NOT EXISTS 会跳过重建，
--     重试前先检查并清理：
--       SELECT i.relname, x.indisvalid FROM pg_class i JOIN pg_index x ON x.indexrelid = i.oid
--        WHERE i.relname = 'idx_ip_geolite2_city_network_gist';
--       -- 若 indisvalid = false：DROP INDEX CONCURRENTLY platform.idx_ip_geolite2_city_network_gist;
-- migrate:up transaction:false

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ip_geolite2_city_network_gist
    ON platform.ip_geolite2_city USING gist (network inet_ops);

-- migrate:down transaction:false

DROP INDEX CONCURRENTLY IF EXISTS platform.idx_ip_geolite2_city_network_gist;
