#!/bin/bash
set -e

DB_URL="$1"
if [ -z "$DB_URL" ]; then
    echo "Usage: $0 <database_url>"
    exit 1
fi

DB_DIR="$(cd "$(dirname "$0")/../db" && pwd)"

# 扫描所有 SQL 文件（按目录层级排序）
# 顺序: src → api_v1 → init → migrations
for f in \
    $(find "$DB_DIR/src" -name "*.sql" | sort) \
    $(find "$DB_DIR/api_v1" -name "*.sql" | sort) \
    $(find "$DB_DIR/init" -name "*.sql" 2>/dev/null | sort) \
    $(find "$DB_DIR/migrations" -name "*.sql" 2>/dev/null | sort); do
    echo "Applying: "$f""
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "All SQL files applied successfully."
