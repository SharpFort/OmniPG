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

# 1. 渲染并复制环境配置（render-config.sh 展开 ${VAR} 占位符；CI Secrets 注入）
echo ""
echo "[1/5] 渲染并复制环境配置..."
RENDER_DIR="$PROJECT_DIR/.deploy-render"
bash "$SCRIPT_DIR/render-config.sh" "$ENV" "$RENDER_DIR"
cp "$RENDER_DIR/.env" .env
chmod 600 .env   # 含密钥的渲染产物默认 umask 下全域可读（批次2d前置 S-F17）
echo "  ✅ gateway/.env 已生成（渲染自 .env.$ENV，权限 600）"

# 2. 拉取最新镜像
echo ""
echo "[2/5] 拉取最新镜像..."
docker compose pull --ignore-pull-failures || true

# 3. 重启服务
echo ""
echo "[3/5] 重启服务..."
docker compose down
docker compose up -d

# 4.（原"加载环境变量供 init-apisix-routes.sh 使用"块——批次2d前置清理：
#    本脚本从未调用 init-apisix-routes.sh，export 亦随进程退出即失效，属死代码；
#    APISIX 初始化由 deploy-all.sh [4/5] / Makefile 独立执行并自行加载所需变量）

# 5. 等待健康检查
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

check_service "APISIX" "http://localhost:7085/status"
check_service "PostgREST" "http://localhost:3100/"
check_service "Logto" "http://localhost:3001/oidc/.well-known/openid-configuration"
check_service "Swagger" "http://localhost:8082/"

echo ""
echo "========================================"
echo "  网关部署完成!"
echo "========================================"
