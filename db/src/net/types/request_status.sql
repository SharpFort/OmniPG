-- db/src/net/types/request_status.sql
-- 语义: pg_net 异步 HTTP 请求状态（net schema 遗留枚举）
--       使用位置: 历史遗留（T7 时代 net 相关表已退役；无现役列引用）
-- 演进史: v1 三值（T7 时代创建）；2026-08-15 用户拍板保留并归位代码（17 号铁律 §8.7）
-- 废弃值: 无（值只增不删；废弃用 z_deprecated_* 前缀 RENAME VALUE，永不删除）
-- 排序语义: 状态机顺序（PENDING → SUCCESS/ERROR），勿重排

-- ① 当前态全量值（只追加、不重排、不删除）
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typname = 'request_status' AND n.nspname = 'net'
    ) THEN
        CREATE TYPE net.request_status AS ENUM ('PENDING', 'SUCCESS', 'ERROR');
    END IF;
END $$;

COMMENT ON TYPE net.request_status IS 'pg_net 异步 HTTP 请求状态（历史遗留保留）: PENDING=待处理 / SUCCESS=成功 / ERROR=失败';
