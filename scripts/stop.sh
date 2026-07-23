#!/bin/bash
# =============================================================================
# OmniPG 一键停止脚本
# 用途：停止完整的 OmniPG 开发环境
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[OK]${NC} $*"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

echo "=========================================="
echo "  OmniPG 开发环境停止"
echo "=========================================="

# Step 1: 停止 Docker Compose
log_step "停止 Docker Compose..."
cd /mnt/e/Projects/OmniPG 2>/dev/null || cd ~/OmniPG 2>/dev/null || true
docker compose down 2>/dev/null || true
log_info "Docker Compose 已停止"

# Step 2: 停止 pgBouncer
log_step "停止 pgBouncer..."
pkill pgbouncer 2>/dev/null || true
log_info "pgBouncer 已停止"

# Step 3: 停止其他服务（保留核心）
log_step "停止其他服务..."
systemctl stop grafana-server 2>/dev/null || true
log_info "Grafana 已停止"

echo ""
log_info "核心服务（PG/Redis/etcd）保持运行"
log_info "如需完全停止：systemctl stop postgresql@18-main redis-server etcd nginx haproxy"
