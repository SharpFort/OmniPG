#!/bin/bash
# =============================================================================
# 数据库部署脚本
# 用法: ./scripts/deploy-db.sh <environment>
# 示例: ./scripts/deploy-db.sh development
# =============================================================================

set -euo pipefail

ENV=${1:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "  数据库部署"
echo "  环境: $ENV"
echo "========================================"

# 加载环境变量
if [ -f "$PROJECT_DIR/.env.$ENV" ]; then
    export $(grep -v '^#' "$PROJECT_DIR/.env.$ENV" | xargs)
fi

# 设置数据库连接
DB_URI=${DB_URI:-"postgres://app_owner:dev_password_change_me@localhost:5432/app_db?sslmode=disable"}
DBMATE_URL=${DBMATE_DATABASE_URL:-"$DB_URI"}

cd "$PROJECT_DIR/db"

# 1. 应用 dbmate 迁移
echo ""
echo "[1/3] 应用数据库迁移..."
export DBMATE_DATABASE_URL="$DBMATE_URL"
dbmate up

# 2. 刷入幂等源码
echo ""
echo "[2/3] 刷入幂等源码..."
bash "$SCRIPT_DIR/apply-src.sh" "$DB_URI"

# 3. 验证
echo ""
echo "[3/3] 验证部署..."
dbmate status

echo ""
echo "========================================"
echo "  数据库部署完成!"
echo "========================================"
