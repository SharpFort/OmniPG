#!/bin/bash
# =============================================================================
# 测试环境一键部署脚本
# 用法: ./scripts/deploy-all.sh <environment>
# 功能: 编排 deploy-infra.sh → deploy-db.sh → deploy-gateway.sh → setup_apisix.sh
# 适用场景:
#   - ⚠️ 仅适用于 Phase 1 单机环境（DB + 网关在同一服务器）
#   - WSL2 开发环境初始化
#   - 测试服务器重建
#   - 灾难恢复
# =============================================================================

set -euo pipefail

ENV=${1:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "  OmniPG 一键部署"
echo "  环境: $ENV"
echo "=========================================="
echo ""

# 1. 基础设施部署
echo "[1/5] 部署基础设施..."
if ! bash "$SCRIPT_DIR/deploy-infra.sh" "$ENV"; then
    echo "❌ 基础设施部署失败"
    exit 1
fi

# 2. 数据库部署
echo ""
echo "[2/5] 部署数据库..."
if ! bash "$SCRIPT_DIR/deploy-db.sh" "$ENV"; then
    echo "❌ 数据库部署失败"
    exit 1
fi

# 3. 网关部署
echo ""
echo "[3/5] 部署网关..."
if ! bash "$SCRIPT_DIR/deploy-gateway.sh" "$ENV"; then
    echo "❌ 网关部署失败"
    exit 1
fi

# 4. APISIX 初始化
echo ""
echo "[4/5] 初始化 APISIX..."
cd "$PROJECT_DIR/gateway"
if ! bash "$SCRIPT_DIR/setup_apisix.sh"; then
    echo "⚠️ APISIX 初始化失败（可能路由已存在）"
fi
cd "$PROJECT_DIR"

# 5. E2E 测试
echo ""
echo "[5/5] 运行端到端测试..."
if ! bash "$SCRIPT_DIR/e2e-test.sh"; then
    echo "⚠️ E2E 测试失败，请检查服务状态"
    exit 1
fi

echo ""
echo "=========================================="
echo "  ✅ 一键部署完成！"
echo "=========================================="
