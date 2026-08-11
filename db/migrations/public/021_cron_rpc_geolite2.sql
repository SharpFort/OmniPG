-- =============================================================================
-- 021_cron_rpc_geolite2.sql — pg_cron 只读 RPC + GeoLite2 兜底 + 登录日志视图
-- =============================================================================
-- 背景: 2026-08-04 用户拍板
--   D-E   pg_cron.job + job_run_details 经只读 RPC 暴露（不建 sys_job 表）
--   P2-24 登录地点经纬度：ip_geolite2_city（GeoLite2-City CSV 导入），
--         查询顺序 ip2region 优先 → GeoLite2 兜底（geo_locate）
--   登录日志 = Logto 推送（sys_login_log）+ IP 归属（ip_region_v4 / ip_geolite2_city）
--         组合视图 v_sys_login_log（实时 join geo_locate，含经纬度/时区）
-- 数据源:
--   - GeoLite2-City-CSV（MaxMind 官方，需账号 license key）:
--     https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City-CSV&license_key=KEY&suffix=zip
--   - 导入: scripts/import-geolite2.sh（下载→解压→COPY staging→import_geolite2_city()）
-- 无 down 段: apply-src 全文件幂等重放；回滚走 pg_dump。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- §1 pg_cron 只读 RPC（D-E；cron schema 由 pg_cron 扩展提供）
--     SECURITY DEFINER + is_super_admin() 门槛（cron 任务为平台级运维信息）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_v1_sys.rpc_list_cron_jobs()
RETURNS TABLE(jobid bigint, jobname text, schedule text, command text,
              nodename text, nodeport integer, database text, username text, active boolean)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    -- 仅超管可查看任务定义（平台级运维信息，非租户级）
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT c.jobid, c.jobname, c.schedule, c.command, c.nodename, c.nodeport,
           c.database, c.username, c.active
    FROM cron.job c
    ORDER BY c.jobid;
END;
$$;
COMMENT ON FUNCTION api_v1_sys.rpc_list_cron_jobs() IS 'pg_cron 任务定义只读查询（超管）；管理端"查看已设置任务"用';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_list_cron_jobs() TO web_anon;

CREATE OR REPLACE FUNCTION api_v1_sys.rpc_list_cron_job_runs(p_limit int DEFAULT 100)
RETURNS TABLE(runid bigint, jobid bigint, status text, return_message text,
              start_time timestamptz, end_time timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT is_super_admin() THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
    FROM cron.job_run_details d
    ORDER BY d.runid DESC
    LIMIT GREATEST(1, LEAST(p_limit, 1000));
END;
$$;
COMMENT ON FUNCTION api_v1_sys.rpc_list_cron_job_runs(int) IS 'pg_cron 运行历史只读查询（超管，默认最近 100 条，上限 1000）';
GRANT EXECUTE ON FUNCTION api_v1_sys.rpc_list_cron_job_runs(int) TO web_anon;

-- ---------------------------------------------------------------------------
-- §2 ip_geolite2_city 表（GeoLite2-City 合并数据，只读）
--     来源: GeoLite2-City-Blocks-IPv4.csv × GeoLite2-City-Locations-zh-CN.csv join
--     查询: network >>= ip（CIDR 包含）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ip_geolite2_city (
    network         CIDR PRIMARY KEY,
    geoname_id      BIGINT,
    latitude        FLOAT8,
    longitude       FLOAT8,
    accuracy_radius INT,
    timezone        TEXT,
    country_name    TEXT,
    city_name       TEXT
);
COMMENT ON TABLE ip_geolite2_city IS 'GeoLite2-City 离线库（Blocks×Locations join 导入，只读）；全球覆盖含经纬度/时区；ip2region 未命中或 IPv6 时兜底';

-- staging 表（导入管道专用，脚本 COPY 后由 import_geolite2_city() 转换）
CREATE TABLE IF NOT EXISTS ip_geolite2_blocks (
    network         CIDR NOT NULL,
    geoname_id      BIGINT,
    registered_country_geoname_id BIGINT,
    represented_country_geoname_id BIGINT,
    is_anonymous_proxy BOOLEAN,
    is_satellite_provider BOOLEAN,
    postal_code     TEXT,
    latitude        FLOAT8,
    longitude       FLOAT8,
    accuracy_radius INT
);
CREATE TABLE IF NOT EXISTS ip_geolite2_locations (
    geoname_id      BIGINT NOT NULL,
    locale_code     TEXT NOT NULL,
    continent_code  TEXT,
    continent_name  TEXT,
    country_iso_code TEXT,
    country_name    TEXT,
    subdivision_1_iso_code TEXT,
    subdivision_1_name TEXT,
    subdivision_2_iso_code TEXT,
    subdivision_2_name TEXT,
    city_name       TEXT,
    metro_code      INT,
    time_zone       TEXT,
    is_in_european_union BOOLEAN
);
COMMENT ON TABLE ip_geolite2_blocks IS 'GeoLite2-City-Blocks-IPv4.csv staging（导入管道）';
COMMENT ON TABLE ip_geolite2_locations IS 'GeoLite2-City-Locations-zh-CN.csv staging（导入管道）';

ALTER TABLE public.ip_geolite2_city ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS geolite2_read_policy ON public.ip_geolite2_city;
CREATE POLICY geolite2_read_policy ON public.ip_geolite2_city
FOR SELECT
USING (true);

-- ---------------------------------------------------------------------------
-- §3 geo_locate(ip) — ip2region 优先 → GeoLite2 兜底（返回 jsonb 统一结构）
-- ---------------------------------------------------------------------------
-- 修正 020 版 ip2region：增加 family(ip)=4 过滤（避免 IPv6 查询误入 IPv4 段）
CREATE OR REPLACE FUNCTION ip2region(ip inet) RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = public, pg_temp
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
COMMENT ON FUNCTION geo_locate(inet) IS 'IP 地理定位：ip2region 优先（国家|省|市|ISP）→ GeoLite2 兜底（全球+经纬度+时区）；返回 {source, region, latitude, longitude, timezone, country, city}';

-- ---------------------------------------------------------------------------
-- §4 登录日志组合视图（Logto 推送日志 + IP 归属实时 join）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_sys_login_log CASCADE;
CREATE VIEW api_v1_sys.v_sys_login_log AS
SELECT l.id, l.tenant_id, l.user_id, l.username, l.login_type, l.result,
       l.fail_reason, l.ip, l.user_agent,
       l.region                 AS region_snapshot,   -- 写入时 ip2region 快照
       g->>'region'             AS region_live,       -- 实时归属（含 GeoLite2 兜底）
       g->>'source'             AS geo_source,
       (g->>'latitude')::float8 AS latitude,
       (g->>'longitude')::float8 AS longitude,
       g->>'timezone'           AS timezone,
       l.logto_event, l.created_at
FROM sys_login_log l
LEFT JOIN LATERAL geo_locate(l.ip) g ON true;
COMMENT ON VIEW api_v1_sys.v_sys_login_log IS '登录日志视图：sys_login_log（Logto PostSignIn 推送）+ geo_locate 实时地理信息（ip2region→GeoLite2）';

-- ---------------------------------------------------------------------------
-- §5 导入函数 import_geolite2_city() — staging → 正式表（幂等全量替换）
--     由 scripts/import-geolite2.sh 在 COPY staging 后调用
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION import_geolite2_city() RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
COMMENT ON FUNCTION import_geolite2_city() IS 'GeoLite2 staging → ip_geolite2_city 全量替换（幂等）；返回导入行数；调用前须已 COPY 两 staging 表';

-- ---------------------------------------------------------------------------
-- §6 验证
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_fn int; v_tbl int; v_view int;
BEGIN
    SELECT count(*) INTO v_fn FROM pg_proc
      WHERE proname IN ('rpc_list_cron_jobs','rpc_list_cron_job_runs','geo_locate','import_geolite2_city');
    SELECT count(*) INTO v_tbl FROM pg_tables
      WHERE schemaname='public' AND tablename IN ('ip_geolite2_city','ip_geolite2_blocks','ip_geolite2_locations');
    SELECT count(*) INTO v_view FROM pg_views
      WHERE schemaname='api_v1_sys' AND viewname='v_sys_login_log';
    RAISE NOTICE '021: 函数=%（期望4） 表=%（期望3） 视图=%（期望1）', v_fn, v_tbl, v_view;
END $$;
