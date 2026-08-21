-- src/platform/functions/logto_ts.sql
-- FUNCTION: platform.logto_ts（17 号文档归位：迁移 010_logto_webhook_rpc.sql 删定义段，本文件为唯一权威）
-- 回放终态: 010_logto_webhook_rpc.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION logto_ts(v text) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    IF v ~ '^[0-9]+$' THEN
        -- 毫秒时间戳（13 位）或秒（10 位）
        IF length(v) >= 13 THEN
            RETURN to_timestamp(v::bigint / 1000.0);
        ELSE
            RETURN to_timestamp(v::bigint);
        END IF;
    END IF;
    RETURN v::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END $$;
