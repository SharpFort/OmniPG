#!/bin/bash
# =============================================================================
# 网关部署脚本
# 用法: ./scripts/deploy-gateway.sh <environment>
# 示例: ./scripts/deploy-gateway.sh development
# =============================================================================

set -euo pipefail

ENV=${1:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "  网关部署"
echo "  环境: $ENV"
echo "========================================"

cd "$PROJECT_DIR/gateway"

# 1. 复制环境配置
echo ""
echo "[1/5] 复制环境配置..."
if [ -f "$PROJECT_DIR/.env.$ENV" ]; then
    cp "$PROJECT_DIR/.env.$ENV" .env
    echo "  已复制 .env.$ENV"
else
    echo "  警告: 未找到 .env.$ENV，使用默认配置"
fi

# 2. 拉取最新镜像
echo ""
echo "[2/5] 拉取最新镜像..."
docker compose pull

# 3. 重启服务
echo ""
echo "[3/5] 重启服务..."
docker compose down
docker compose up -d

# 4. 等待健康检查
echo ""
echo "[4/5] 等待服务启动..."
sleep 15

# 5. 验证服务
echo ""
echo "[5/5] 健康检查..."
check_service() {
    local name=$1
    local url=$2
    if curl -sf "$url" > /dev/null 2>&1; then
        echo "  ✅ $name"
        return 0
    else
        echo "  ❌ $name"
        return 1
    fi
}

check_service "APISIX" "http://localhost:9080/apisix/status"
check_service "PostgREST" "http://localhost:3001/"
check_service "Casdoor" "http://localhost:8000/api/health"
check_service "Syncer" "http://localhost:8080/healthz"
check_service "Swagger" "http://localhost:8082/"

echo ""
echo "========================================"
echo "  网关部署完成!"
echo "========================================"
