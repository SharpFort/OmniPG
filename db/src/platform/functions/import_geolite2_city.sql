-- src/platform/functions/import_geolite2_city.sql
-- FUNCTION: platform.import_geolite2_city（17 号文档归位：迁移 021_cron_rpc_geolite2.sql 删定义段，本文件为唯一权威）
-- 回放终态: 021_cron_rpc_geolite2.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION import_geolite2_city() RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = platform, ext, pg_temp
AS $$
DECLARE
    v_cnt int;
BEGIN
    TRUNCATE ip_geolite2_city;
    INSERT INTO ip_geolite2_city
        (network, geoname_id, latitude, longitude, accuracy_radius,
         timezone, country_name, city_name)
    SELECT b.network, b.geoname_id, b.latitude, b.longitude, b.accuracy_radius,
           l.time_zone, l.country_name, l.city_name
    FROM ip_geolite2_blocks b
    LEFT JOIN ip_geolite2_locations l
           ON l.geoname_id = b.geoname_id AND l.locale_code = 'zh-CN';
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    RETURN v_cnt;
END;
$$;
