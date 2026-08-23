#!/bin/bash
# =============================================================================
# 数据库迁移快捷入口
# 用法: ./scripts/migrate.sh <command> <environment>
# 示例: ./scripts/migrate.sh up development
# =============================================================================

set -euo pipefail

COMMAND=${1:-status}
ENV=${2:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 加载环境变量
if [ -f "$PROJECT_DIR/.env.$ENV" ]; then
    export $(grep -v '^#' "$PROJECT_DIR/.env.$ENV" | xargs)
fi

# 设置数据库连接
DB_URI=${DB_URI:-"postgres://app_owner:admin%40password@localhost:5432/app_db?sslmode=disable"}
DBMATE_URL=${DATABASE_URL:-"$DB_URI"}

cd "$PROJECT_DIR/db"

export DATABASE_URL="$DBMATE_URL"

case "$COMMAND" in
    up)
        echo "应用数据库迁移..."
        dbmate -d migrations/platform up
        ;;
    down|rollback)
        echo "回滚最近一次迁移..."
        dbmate -d migrations/platform rollback
        ;;
    status)
        echo "迁移状态:"
        dbmate -d migrations/platform status
        ;;
    create)
        if [ -z "${3:-}" ]; then
            echo "用法: $0 create <migration_name>"
            exit 1
        fi
        echo "创建迁移: $3"
        dbmate new "$3"
        ;;
    *)
        echo "用法: $0 {up|down|status|create} <environment>"
        exit 1
        ;;
esac
