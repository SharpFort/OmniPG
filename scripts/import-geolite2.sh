#!/bin/bash
# =============================================================================
# import-geolite2.sh — GeoLite2-City 数据导入（P2-24 落地，ip2region 兜底）
# =============================================================================
# 用法: MAXMIND_LICENSE_KEY=xxx bash scripts/import-geolite2.sh [PG_DSN]
#   - 需 MaxMind 免费账号 license key: https://www.maxmind.com/en/geolite2/signup
#   - 流程: 下载 GeoLite2-City-CSV → 解压 → COPY staging（021 迁移建表）
#           → 调用 PG 函数 import_geolite2_city() 转换到 ip_geolite2_city
#   - 查询顺序: ip2region 优先（ip_region_v4，国内精度高）→ GeoLite2 兜底
#     （geo_locate() 函数，全球 + 经纬度 + 时区，含 IPv6）
# =============================================================================
set -euo pipefail

PG_DSN="${1:-postgresql://postgres@127.0.0.1:5432/app_db}"
: "${MAXMIND_LICENSE_KEY:?请设置 MAXMIND_LICENSE_KEY 环境变量（MaxMind 免费账号）}"

URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City-CSV&license_key=${MAXMIND_LICENSE_KEY}&suffix=zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> 下载 GeoLite2-City-CSV（${URL}）"
curl -fsSL "$URL" -o "$TMP_DIR/geolite2.zip"
cd "$TMP_DIR"
unzip -q geolite2.zip
DIR="$(find . -maxdepth 1 -type d -name 'GeoLite2-City-CSV_*' | head -1)"
[ -n "$DIR" ] || { echo "解压目录未找到"; exit 1; }
echo "解压目录: $DIR"

echo "==> COPY staging（Blocks-IPv4 + Locations-zh-CN，全 14 列）"
psql "$PG_DSN" <<SQL
TRUNCATE ip_geolite2_blocks;
TRUNCATE ip_geolite2_locations;
\COPY ip_geolite2_blocks (network, geoname_id, registered_country_geoname_id, represented_country_geoname_id, is_anonymous_proxy, is_satellite_provider, postal_code, latitude, longitude, accuracy_radius)
FROM '$TMP_DIR/$DIR/GeoLite2-City-Blocks-IPv4.csv'
WITH (FORMAT csv, HEADER true, NULL '');
\COPY ip_geolite2_locations (geoname_id, locale_code, continent_code, continent_name, country_iso_code, country_name, subdivision_1_iso_code, subdivision_1_name, subdivision_2_iso_code, subdivision_2_name, city_name, metro_code, time_zone, is_in_european_union)
FROM '$TMP_DIR/$DIR/GeoLite2-City-Locations-zh-CN.csv'
WITH (FORMAT csv, HEADER true, NULL '');
SQL

echo "==> 调用 PG 函数 import_geolite2_city() 转换（staging → 正式表）"
psql "$PG_DSN" -c "SELECT import_geolite2_city() AS rows_imported;"

echo "==> 抽样验证 geo_locate()"
psql "$PG_DSN" -c "SELECT geo_locate('114.114.114.114'::inet) AS cn_sample;"
psql "$PG_DSN" -c "SELECT geo_locate('8.8.8.8'::inet) AS global_sample;"
echo "==> 完成"
