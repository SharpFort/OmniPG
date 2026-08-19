#!/bin/bash
# =============================================================================
# 基础设施部署脚本（2026-08-19 方案 A：单文件 pigsty.yml + 官方多剧本模式）
# 用法:
#   ./scripts/deploy-infra.sh all <environment>        # Phase 1 单机全栈
#   ./scripts/deploy-infra.sh db <environment>         # Phase 2 DB 服务器（pgsql/infra/etcd/vibe）
#   ./scripts/deploy-infra.sh gateway <environment>    # Phase 2 网关服务器（node/docker/redis）
# 多机部署时用 LIMIT 环境变量指定本机 IP（ansible -l 主机限制，默认 127.0.0.1）：
#   LIMIT=10.0.0.10 ./scripts/deploy-infra.sh db production
# 参考: 剧本列表 http://pigsty.cc/docs/ref/playbook/ ·
#       配置清单 https://doc.pigsty.cc/docs/concept/iac/inventory/
# =============================================================================

set -euo pipefail

MODE=${1:-all}  # all, db, gateway
ENV=${2:-development}
LIMIT=${LIMIT:-127.0.0.1}  # 多机部署时传本机 IP（ansible -l 主机限制）
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

# 2. 复制唯一配置文件（方案 A：官方单文件 inventory；pigsty.db.yml / pigsty.gateway.yml
#    已于 2026-08-19 合并删除，多角色通过官方剧本 + -l 主机限制表达）
echo ""
echo "[2/5] 复制唯一配置文件（infra/pigsty.yml）..."
CONFIG_FILE="$PROJECT_DIR/infra/pigsty.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "  ❌ 配置文件缺失: $CONFIG_FILE"
    exit 1
fi
cp "$CONFIG_FILE" "$HOME/pigsty/pigsty.yml"
echo "  ✅ pigsty.yml 已复制（唯一 inventory）"

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

# 4. 执行官方剧本（单文件 inventory + ansible 主机限制）
echo ""
echo "[4/5] 执行 Pigsty 官方剧本（模式: $MODE, LIMIT: $LIMIT）..."
cd "$HOME/pigsty"
case "$MODE" in
    all)
        if [ -f "./deploy.yml" ]; then
            ./deploy.yml && echo "  ✅ deploy.yml 执行完成"
        elif [ -f "./install.yml" ]; then
            ./install.yml && echo "  ✅ install.yml 执行完成"
        else
            echo "  ❌ 未找到 deploy.yml / install.yml"
            exit 1
        fi
        if [ -f "./etcd.yml" ]; then
            ./etcd.yml && echo "  ✅ etcd.yml 执行完成"
        fi
        ;;
    db)
        for pb in pgsql.yml infra.yml etcd.yml vibe.yml; do
            if [ -f "./$pb" ]; then
                echo "  ▶ $pb -l $LIMIT ..."
                ./$pb -l "$LIMIT"
                echo "  ✅ $pb 执行完成"
            else
                echo "  ⚠️ $pb 不存在，跳过"
            fi
        done
        ;;
    gateway)
        for pb in node.yml docker.yml redis.yml; do
            if [ -f "./$pb" ]; then
                echo "  ▶ $pb -l $LIMIT ..."
                ./$pb -l "$LIMIT"
                echo "  ✅ $pb 执行完成"
            else
                echo "  ⚠️ $pb 不存在，跳过"
            fi
        done
        ;;
    *)
        echo "  ❌ 未知模式: $MODE (可选: all, db, gateway)"
        exit 1
        ;;
esac

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
