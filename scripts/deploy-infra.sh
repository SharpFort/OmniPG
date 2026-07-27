#!/bin/bash
# =============================================================================
# 基础设施部署脚本
# 用法: 
#   首次部署: ./scripts/deploy-infra.sh <environment>
#   Phase 2 DB: ./scripts/deploy-infra.sh db <environment>
#   Phase 2 GW: ./scripts/deploy-infra.sh gateway <environment>
# 示例: ./scripts/deploy-infra.sh development
# =============================================================================

set -euo pipefail

MODE=${1:-all}  # all, db, gateway
ENV=${2:-development}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "========================================"
echo "  基础设施部署"
echo "  模式: $MODE"
echo "  环境: $ENV"
echo "========================================"

# 加载环境变量
if [ -f "$PROJECT_DIR/.env.$ENV" ]; then
    export $(grep -v '^#' "$PROJECT_DIR/.env.$ENV" | xargs)
fi

# 1. 检测 Pigsty 是否已安装
echo ""
echo "[1/5] 检测 Pigsty 安装状态..."
if [ -d "$HOME/pigsty" ]; then
    echo "  ✅ Pigsty 已安装: $HOME/pigsty"
    cd "$HOME/pigsty"
else
    echo "  ⚠️ Pigsty 未安装，开始下载..."
    cd "$HOME"
    curl -fsSL https://pigsty.cc/get | bash -s v4.4.0
    cd "$HOME/pigsty"
    echo "  ✅ Pigsty 下载完成"
fi

# 2. 选择配置文件
echo ""
echo "[2/5] 选择配置文件..."
case "$MODE" in
    db)
        CONFIG_FILE="$PROJECT_DIR/infra/pigsty.db.yml"
        echo "  使用 DB 服务器配置: pigsty.db.yml"
        ;;
    gateway)
        CONFIG_FILE="$PROJECT_DIR/infra/pigsty.gateway.yml"
        echo "  使用网关服务器配置: pigsty.gateway.yml"
        ;;
    all)
        CONFIG_FILE="$PROJECT_DIR/infra/pigsty.yml"
        echo "  使用单机完整配置: pigsty.yml"
        ;;
    *)
        echo "  ❌ 未知模式: $MODE (可选: all, db, gateway)"
        exit 1
        ;;
esac

# 3. 复制配置文件
echo ""
echo "[3/5] 复制配置文件..."
cp "$CONFIG_FILE" "$HOME/pigsty/pigsty.yml"
echo "  ✅ pigsty.yml 已复制"

# 根据模式复制额外配置文件
if [ "$MODE" = "all" ] || [ "$MODE" = "db" ]; then
    # 复制 PG 相关配置（pg_hba.conf 由 pigsty.yml 中的 pg_hba_rules 生成，无需单独复制）
    if [ -f "$PROJECT_DIR/infra/pgbouncer.ini" ]; then
        sudo mkdir -p /etc/pgbouncer
        sudo cp "$PROJECT_DIR/infra/pgbouncer.ini" /etc/pgbouncer/pgbouncer.ini
        echo "  ✅ pgbouncer.ini 已复制"
    fi
    if [ -f "$PROJECT_DIR/infra/userlist.txt" ]; then
        sudo mkdir -p /etc/pgbouncer
        sudo cp "$PROJECT_DIR/infra/userlist.txt" /etc/pgbouncer/userlist.txt
        sudo chmod 640 /etc/pgbouncer/userlist.txt
        echo "  ✅ userlist.txt 已复制"
    fi
    if [ -f "$PROJECT_DIR/infra/redis.conf" ]; then
        sudo cp "$PROJECT_DIR/infra/redis.conf" /etc/redis/redis.conf
        echo "  ✅ redis.conf 已复制"
    fi
fi

# 4. 执行 Pigsty 部署
echo ""
echo "[4/5] 执行 Pigsty 部署..."
cd "$HOME/pigsty"
if [ -f "./deploy.yml" ]; then
    ./deploy.yml
    echo "  ✅ deploy.yml 执行完成"
else
    echo "  ❌ deploy.yml 不存在"
    exit 1
fi

# 部署 etcd
if [ -f "./etcd.yml" ]; then
    ./etcd.yml
    echo "  ✅ etcd.yml 执行完成"
fi

# 5. 验证服务
echo ""
echo "[5/5] 验证服务状态..."
ERRORS=0

# PostgreSQL
if PGPASSWORD=${DB_PASSWORD:-dev_password_change_me} psql -h 127.0.0.1 -U app_owner -d app_db -c "SELECT 1" &>/dev/null; then
    echo "  ✅ PostgreSQL: 连接成功"
else
    echo "  ❌ PostgreSQL: 连接失败"
    ((ERRORS++))
fi

# pgBouncer
if PGPASSWORD=${DB_PASSWORD:-dev_password_change_me} psql -h 127.0.0.1 -p 6432 -U app_owner -d app_db -c "SELECT 1" &>/dev/null; then
    echo "  ✅ pgBouncer: 连接成功"
else
    echo "  ❌ pgBouncer: 连接失败"
    ((ERRORS++))
fi

# Redis
if redis-cli ping 2>/dev/null | grep -q PONG; then
    echo "  ✅ Redis: PONG"
else
    echo "  ❌ Redis: 无响应"
    ((ERRORS++))
fi

# etcd
if curl -sk https://127.0.0.1:2379/health 2>/dev/null | grep -q "true\|ok\|healthy"; then
    echo "  ✅ etcd: healthy"
else
    echo "  ⚠️ etcd: 可能需要检查"
fi

echo ""
echo "========================================"
if [ $ERRORS -gt 0 ]; then
    echo "  ⚠️ 部署完成，有 $ERRORS 个服务验证失败"
    exit 1
else
    echo "  ✅ 基础设施部署完成！"
fi
echo "========================================"
