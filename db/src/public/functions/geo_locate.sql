-- src/public/functions/geo_locate.sql
-- FUNCTION: public.geo_locate（17 号文档归位：迁移 021_cron_rpc_geolite2.sql 删定义段，本文件为唯一权威）
-- 回放终态: 021_cron_rpc_geolite2.sql；幂等写法（§9 模板）

CREATE OR REPLACE FUNCTION geo_locate(ip inet) RETURNS jsonb
LANGUAGE plpgsql
STABLE
STRICT
SET search_path = public, pg_temp
AS $$
DECLARE
    v_region   text;
    v_cidr     cidr;
    v_row      record;
    v_lat      float8;
    v_lon      float8;
    v_tz       text;
    v_country  text;
    v_city     text;
BEGIN
    -- ① ip2region 优先（仅 IPv4，国内精度高）
    v_region := ip2region(ip);

    -- ② GeoLite2 兜底（IPv4 未命中 或 IPv6）
    BEGIN
        v_cidr := ip::cidr;   -- inet → cidr（/32 或 /128）
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    SELECT g.latitude, g.longitude, g.timezone, g.country_name, g.city_name
      INTO v_lat, v_lon, v_tz, v_country, v_city
    FROM ip_geolite2_city g
    WHERE g.network >>= v_cidr
    ORDER BY masklen(g.network) DESC
    LIMIT 1;

    IF v_region IS NOT NULL THEN
        RETURN jsonb_build_object(
            'source', 'ip2region', 'region', v_region,
            'latitude', v_lat, 'longitude', v_lon,
            'timezone', v_tz, 'country', v_country, 'city', v_city);
    ELSIF v_city IS NOT NULL OR v_country IS NOT NULL OR v_lat IS NOT NULL THEN
        RETURN jsonb_build_object(
            'source', 'geolite2', 'region', NULL,
            'latitude', v_lat, 'longitude', v_lon,
            'timezone', v_tz, 'country', v_country, 'city', v_city);
    ELSE
        RETURN NULL;
    END IF;
END;
$$;
