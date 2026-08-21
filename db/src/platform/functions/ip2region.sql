-- src/platform/functions/ip2region.sql
-- FUNCTION: platform.ip2region（17 号文档归位：迁移 021_cron_rpc_geolite2.sql 删定义段，本文件为唯一权威）
-- 回放终态: 021_cron_rpc_geolite2.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION ip2region(ip inet) RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = platform, ext, pg_temp
AS $$
    SELECT country
           || CASE WHEN province IS NOT NULL AND province <> '' THEN '|' || province ELSE '' END
           || CASE WHEN city     IS NOT NULL AND city     <> '' THEN '|' || city     ELSE '' END
           || CASE WHEN isp      IS NOT NULL AND isp      <> '' THEN '|' || isp      ELSE '' END
    FROM ip_region_v4
    WHERE family(ip) = 4
      AND start_ip <= ip AND end_ip >= ip
    ORDER BY start_ip DESC
    LIMIT 1;
$$;
