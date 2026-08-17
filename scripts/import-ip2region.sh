#!/bin/bash
# =============================================================================
# import-ip2region.sh — ip2region 数据导入（D-4 落地，零后端 IP 归属解析）
# =============================================================================
# 用法:
#   bash scripts/import-ip2region.sh [数据源] [PG_DSN]
#   数据源:
#     (省略)               → GitHub 免费版 ipv4_source.txt（自动下载，~52 万行）
#     本地文件路径          → 自定义 txt（如官网 V4-基础版下载的原始数据）
#     http(s)://...        → 远程 txt（自动下载）
#   示例:
#   bash scripts/import-ip2region.sh                                # 免费版
#   bash scripts/import-ip2region.sh ./ipv4_source_full.txt         # 官网商业版
#   bash scripts/import-ip2region.sh "https://.../ipv4_source.txt"  # 自定义远程
#
# 数据源说明（2026-08-05 核实）:
#   - GitHub 免费版（默认）: data/ipv4_source.txt，517,743 行，7 字段
#     起始IP|结束IP|国家|省|市|ISP|iso-code；中国到市、全球到国家/地区级；
#     社区维护，更新频率较低。对国内应用已够用（geolite2 兜底补全球经纬度）。
#   - 官网 V4-基础版（商业付费）: ip2region.net 数据服务，22,883,308 行 / 3.4G
#     10 字段（含行政区码/电话区号），IP 段切分更细；前 7 列格式与免费版一致，
#     COPY 只取前 7 列即可无缝升级（同一张 ip_region_v4 表）。
#   - 本脚本幂等: TRUNCATE 后全量重灌；查询走 ip2region(inet) / geo_locate()。
# =============================================================================
set -euo pipefail

SRC="${1:-https://github.com/lionsoul2014/ip2region/raw/master/data/ipv4_source.txt}"
PG_DSN="${2:-postgresql://postgres@127.0.0.1:5432/app_db}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DATA_FILE=""
if [[ "$SRC" =~ ^https?:// ]]; then
    echo "==> 下载 ipv4_source.txt: $SRC"
    curl -fsSL "$SRC" -o "$TMP_DIR/ipv4_source.txt"
    DATA_FILE="$TMP_DIR/ipv4_source.txt"
elif [[ -f "$SRC" ]]; then
    echo "==> 使用本地数据文件: $SRC"
    DATA_FILE="$SRC"
else
    echo "错误: 数据源不存在或无法访问: $SRC" >&2
    exit 1
fi

echo "==> 行数: $(wc -l < "$DATA_FILE")"
echo "==> COPY → ip_region_v4（仅取前 7 列，兼容免费版/商业版）"
psql "$PG_DSN" <<SQL
TRUNCATE ip_region_v4;
\COPY ip_region_v4 (start_ip, end_ip, country, province, city, isp, iso_code)
FROM '$(cygpath -m "$DATA_FILE" 2>/dev/null || echo "$DATA_FILE")'
WITH (FORMAT text, DELIMITER '|', NULL '');
SQL

echo "==> 验证:"
psql "$PG_DSN" -c "SELECT count(*) AS rows_imported FROM ip_region_v4;"
psql "$PG_DSN" -c "SELECT ip2region('1.0.1.0'::inet) AS sample;"
