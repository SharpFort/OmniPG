#!/bin/bash
# =============================================================================
# import-ip2region.sh — ip2region 数据导入（D-4 落地，零后端 IP 归属解析）
# =============================================================================
# 用途: 下载 ip2region v2.0 的 IPv4 原始数据（ipv4_source.txt）并导入
#       ip_region_v4 表（019 迁移创建）。登录日志写时经 ip2region(ip) 函数解析。
# 用法: bash scripts/import-ip2region.sh [PG_DSN]
#       默认 PG_DSN=postgresql://postgres@127.0.0.1:5432/app_db（可覆盖）
# 注意: 需在可访问目标 PG 的机器执行（Pigsty 宿主）；psql 需已安装
# 数据格式（ipv4_source.txt，竖线分隔 7 列）:
#       起始IP|结束IP|国家|省|市|ISP|iso-alpha2-code
# 说明: ip2region 不含经纬度；经纬度 P2（GeoLite2-CSV 同法导入或高德/腾讯 API）
# =============================================================================
set -euo pipefail

PG_DSN="${1:-postgresql://postgres@127.0.0.1:5432/app_db}"
URL="https://github.com/lionsoul2014/ip2region/raw/master/data/ipv4_source.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> 下载 ipv4_source.txt（${URL}）"
curl -fsSL "$URL" -o "$TMP_DIR/ipv4_source.txt"
wc -l "$TMP_DIR/ipv4_source.txt"

echo "==> 导入 ip_region_v4（TRUNCATE 后全量 COPY）"
psql "$PG_DSN" <<SQL
TRUNCATE ip_region_v4;
\COPY ip_region_v4 (start_ip, end_ip, country, province, city, isp, iso_code)
FROM '$TMP_DIR/ipv4_source.txt'
WITH (FORMAT text, DELIMITER '|', NULL '');
SELECT count(*) AS rows_imported FROM ip_region_v4;
SQL

echo "==> 抽样验证 ip2region(inet) 函数"
psql "$PG_DSN" -c "SELECT ip2region('114.114.114.114'::inet) AS region_sample;"
echo "==> 完成"
