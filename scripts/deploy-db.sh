#!/bin/bash
# =============================================================================
# 数据库部署脚本
# 用法: ./scripts/deploy-db.sh <environment> [db_port]
# 示例: ./scripts/deploy-db.sh development          # 宿主 Pigsty PG (5432，默认)
#       ./scripts/deploy-db.sh development 5433     # 备用：指向其他 PG 实例
# 说明: 数据库连接凭据来自 .env.<environment>（DB_USER/DB_PASSWORD），
#       不再在脚本内硬编码密码。
# =============================================================================

set -euo pipefail

ENV=${1:-development}
DB_PORT=${2:-${DB_PORT:-5432}}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  数据库部署"
echo "  环境: $ENV    端口: $DB_PORT"
echo "============================================"

# 加载环境变量
if [ -f "$PROJECT_DIR/.env.$ENV" ]; then
    export $(grep -v '^#' "$PROJECT_DIR/.env.$ENV" | xargs)
fi

DB_USER=${DB_USER:-app_owner}
DB_PASSWORD=${DB_PASSWORD:-dev_password_change_me}
DB_NAME=${DB_NAME:-app_db}
DB_HOST=${DB_HOST:-localhost}

# 设置数据库连接（全部来自环境变量，无硬编码密码）
DB_URI=${DB_URI:-"postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"}
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
echo "============================================"
echo "  数据库部署完成!"
echo "============================================"
