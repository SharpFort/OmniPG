#!/bin/bash
# =============================================================================
# 数据库部署脚本（17 号文档 §3.1 部署链：bootstrap → dbmate up → apply-src 全量）
# 用法: ./scripts/deploy-db.sh <environment> [db_port]
# 示例: ./scripts/deploy-db.sh development          # 宿主 Pigsty PG (5432，默认)
#       ./scripts/deploy-db.sh development 5433     # 备用：指向其他 PG 实例
# 说明: 数据库连接凭据来自 .env.<environment>（DB_USER/DB_PASSWORD），
#       不再在脚本内硬编码密码。
# 流程:
#   [1/4] bootstrap   —— init（扩展/schema/角色）+ src types（枚举）前置
#                        （§3.4 依赖倒置：059/060 迁移引用 src 枚举，必须先建）
#   [2/4] dbmate up   —— 迁移（仅表结构+数据；代码对象归位 src/api_v1）
#   [3/4] apply-src   —— 全量幂等重放（含 §6.3 迁移扫描零容忍 + 迁移幂等重放）
#   [4/4] 验证        —— dbmate status
# 结果一致性: apply-src 全量重放迁移两遍不炸（ddl 均 IF NOT EXISTS/DO 块守卫），
#             再次部署（bootstrap 幂等 + dbmate 跳过已应用 + apply-src 重放）结果一致
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

# 1. bootstrap（init + src types——扩展/枚举前置，冷启动依赖倒置修复）
echo ""
echo "[1/4] bootstrap（init + src types）..."
bash "$SCRIPT_DIR/apply-src.sh" "$DB_URI" --bootstrap

# 2. 应用 dbmate 迁移
echo ""
echo "[2/4] 应用数据库迁移..."
export DBMATE_DATABASE_URL="$DBMATE_URL"
dbmate up

# 3. 刷入幂等源码（含迁移代码对象扫描 + 迁移幂等重放）
echo ""
echo "[3/4] 刷入幂等源码..."
bash "$SCRIPT_DIR/apply-src.sh" "$DB_URI"

# 4. 验证
echo ""
echo "[4/4] 验证部署..."
dbmate status

echo ""
echo "============================================"
echo "  数据库部署完成!"
echo "============================================"
