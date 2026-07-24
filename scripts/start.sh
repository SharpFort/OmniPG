#!/bin/bash
# =============================================================================
# OmniPG 一键启动脚本
# 用途：拉起完整的 OmniPG 开发环境
# 执行：在 WSL2 Ubuntu 26.04 中运行 ./start.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

echo "=========================================="
echo "  OmniPG 开发环境一键启动"
echo "=========================================="
echo ""

# -----------------------------------
# Step 1: 启动核心基础设施 (Pigsty)
# -----------------------------------
log_step "1/5 启动核心基础设施..."

# PostgreSQL
if ! systemctl is-active --quiet postgresql@18-main; then
    pg_ctlcluster 18 main start 2>/dev/null || systemctl start postgresql@18-main
    sleep 2
    log_info "PostgreSQL 已启动"
else
    log_info "PostgreSQL 已在运行"
fi

# pgBouncer (Pigsty 内置)
if ! pgrep -x pgbouncer > /dev/null; then
    sudo -u postgres /usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer.ini &
    sleep 2
    log_info "pgBouncer 已启动 (端口 6432)"
else
    log_info "pgBouncer 已在运行"
fi

# Redis
if ! systemctl is-active --quiet redis-server; then
    systemctl start redis-server
    sleep 1
    log_info "Redis 已启动"
else
    log_info "Redis 已在运行"
fi

# etcd
if ! systemctl is-active --quiet etcd; then
    systemctl start etcd
    sleep 1
    log_info "etcd 已启动"
else
    log_info "etcd 已在运行"
fi

# Grafana
if ! systemctl is-active --quiet grafana-server; then
    systemctl start grafana-server
    sleep 2
    log_info "Grafana 已启动 (端口 3000)"
else
    log_info "Grafana 已在运行"
fi

# -----------------------------------
# Step 2: 启动 Docker (如果可用)
# -----------------------------------
log_step "2/5 检查 Docker..."
if command -v docker &>/dev/null; then
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        log_info "Docker 已安装但未作为服务运行 (Docker Desktop 模式)"
    else
        log_info "Docker 已在运行"
    fi
else
    log_warn "Docker 未安装，请先启用 Docker Desktop WSL2 集成"
fi

# -----------------------------------
# Step 3: 启动 Docker Compose 服务
# -----------------------------------
log_step "3/5 启动 Docker Compose 服务..."
if command -v docker &>/dev/null; then
    cd /mnt/e/Projects/OmniPG
    docker compose up -d 2>/dev/null && log_info "Docker Compose 服务已启动" || log_warn "Docker Compose 启动失败 (可能配置文件未更新)"
else
    log_warn "跳过 Docker Compose (Docker 不可用)"
fi

# -----------------------------------
# Step 4: 验证所有服务
# -----------------------------------
log_step "4/5 验证服务状态..."
ERRORS=0

# PostgreSQL
if PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1" &>/dev/null; then
    log_info "PostgreSQL: 连接成功"
else
    log_error "PostgreSQL: 连接失败"
    ((ERRORS++))
fi

# pgBouncer
if PGPASSWORD=dev_password_change_me psql -h 127.0.0.1 -p 6432 -U app_owner -d app_db -c "SELECT 1" &>/dev/null; then
    log_info "pgBouncer: 连接成功"
else
    log_error "pgBouncer: 连接失败"
    ((ERRORS++))
fi

# Redis
if redis-cli ping | grep -q PONG; then
    log_info "Redis: PONG"
else
    log_error "Redis: 无响应"
    ((ERRORS++))
fi

# etcd
if curl -sk https://127.0.0.1:2379/health 2>/dev/null | grep -q "true\|ok\|healthy"; then
    log_info "etcd: healthy"
else
    log_warn "etcd: 可能需要检查"
fi

# Grafana
if curl -s http://localhost:3000/api/health 2>/dev/null | grep -q "ok"; then
    log_info "Grafana: healthy (端口 3000)"
else
    log_error "Grafana: unhealthy"
    ((ERRORS++))
fi

# -----------------------------------
# Step 5: 输出访问信息
# -----------------------------------
echo ""
echo "=========================================="
echo "  服务访问地址"
echo "=========================================="
echo ""
echo "  PostgreSQL:      localhost:5432 (app_owner/dev_password_change_me)"
echo "  pgBouncer:       localhost:6432 (Pigsty 内置)"
echo "  Redis:           localhost:6379"
echo "  etcd:            https://localhost:2379"
echo "  Grafana:         http://localhost:3000 (admin/pigsty)"
echo "  VictoriaMetrics: http://localhost:8428"
echo "  Nginx:           http://localhost:80"
echo ""
echo "  Docker Compose 服务:"
echo "    APISIX:        http://localhost:9080"
echo "    PostgREST:     http://localhost:3001"
echo "    Casdoor:       http://localhost:8000"
echo "    Swagger UI:    http://localhost:8082"
echo "    Redis(Docker): localhost:6379"
echo ""
echo "=========================================="

if [ $ERRORS -gt 0 ]; then
    log_warn "有 $ERRORS 个服务验证失败，请检查日志"
    exit 1
else
    log_info "所有服务验证通过！"
    exit 0
fi
