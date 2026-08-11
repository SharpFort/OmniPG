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
# 模块顺序显式声明（2026-08-11，sys→public 重命名）:
#   public（基础/系统层，无前缀函数落 public schema）→ inventory → sales
#   依赖方向: 后置模块可依赖前置模块，反之不可；新增模块须在此声明位置
#   api_v1 层前缀 _shared（跨模块共享 API）置首
MODULES="public inventory sales"
API_MODULES="_shared public inventory sales"
for f in \
    $(for m in $MODULES; do find "$DB_DIR/src/$m" -name "*.sql" 2>/dev/null | sort; done) \
    $(for m in $API_MODULES; do find "$DB_DIR/api_v1/$m" -name "*.sql" 2>/dev/null | sort; done) \
    $(find "$DB_DIR/init" -name "*.sql" 2>/dev/null | sort) \
    $(for m in $MODULES; do find "$DB_DIR/migrations/$m" -name "*.sql" 2>/dev/null | sort; done); do
    echo "Applying: "$f""
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "All SQL files applied successfully."
