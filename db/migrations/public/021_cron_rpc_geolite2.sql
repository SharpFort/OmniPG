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

-- ---------------------------------------------------------------------------
-- §3 geo_locate(ip) — ip2region 优先 → GeoLite2 兜底（返回 jsonb 统一结构）
-- ---------------------------------------------------------------------------
-- 修正 020 版 ip2region：增加 family(ip)=4 过滤（避免 IPv6 查询误入 IPv4 段）


-- ---------------------------------------------------------------------------
-- §4 登录日志组合视图（Logto 推送日志 + IP 归属实时 join）
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api_v1_sys.v_sys_login_log CASCADE;


-- ---------------------------------------------------------------------------
-- §5 导入函数 import_geolite2_city() — staging → 正式表（幂等全量替换）
--     由 scripts/import-geolite2.sh 在 COPY staging 后调用
-- ---------------------------------------------------------------------------


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
