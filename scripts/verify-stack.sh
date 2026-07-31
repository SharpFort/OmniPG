#!/bin/bash
# =============================================================================
# OmniPG 全栈验证脚本（一键运行）
# 用法:   bash scripts/verify-stack.sh
# 环境:   WSL2 Ubuntu（Pigsty 宿主 + Docker Desktop），在项目根目录执行
# 覆盖:   docs/审查文档/22号 §七 验证清单（10 项）
# 依赖:   docker, curl, psql（宿主 Pigsty 自带）, python3
# 退出码: 0 = 全部通过；1 = 存在失败项
# 注意:   需要 gateway/.env（cp .env.development gateway/.env）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
FAILED_ITEMS=()

log_pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); FAILED_ITEMS+=("$1"); }

echo "============================================"
echo "  OmniPG 全栈验证"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# ---------------------------------------------------------------- 依赖预检
echo ""
echo "【0/10】依赖预检..."
DEPS_OK=1
for t in docker curl psql python3; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "  ✅ $t"
    else
        echo "  ❌ $t 缺失"
        DEPS_OK=0
    fi
done
[ "$DEPS_OK" = "1" ] || { echo "  依赖缺失，中止。"; exit 1; }

# 加载 gateway/.env（APISIX_ADMIN_KEY / AUTHENTICATOR_PASSWORD 等）
if [ -f gateway/.env ]; then
    set -a; # shellcheck disable=SC1091
    source gateway/.env; set +a
    echo "  ✅ gateway/.env 已加载"
else
    echo "  ⚠️ gateway/.env 不存在，部分检查将使用默认值（建议: cp .env.development gateway/.env）"
fi

# 可覆盖变量
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
AUTHENTICATOR_PASSWORD="${AUTHENTICATOR_PASSWORD:-authenticator_dev_pass}"
LOGIN_USER="${LOGIN_USER:-admin}"
LOGIN_PASS="${LOGIN_PASS:-admin123}"

# ---------------------------------------------------------------- 1/10 网络链路
echo ""
echo "【1/10】网络链路（容器 → 宿主 pgbouncer）..."
NET=$(docker network ls --format '{{.Name}}' | grep -E 'app-net$' | head -1)
if [ -z "$NET" ]; then
    log_fail "找不到 app-net 网络（是否已 docker compose up -d？）"
else
    if docker run --rm --network "$NET" --add-host host.docker.internal:host-gateway \
        alpine sh -c 'nc -z -w3 host.docker.internal 6432' >/dev/null 2>&1; then
        log_pass "容器→宿主 pgbouncer(6432) 可达（网络: $NET）"
    else
        log_fail "容器→宿主 pgbouncer(6432) 不可达。检查: Win11 mirrored / scripts/wsl-portproxy.ps1"
    fi
fi

# ---------------------------------------------------------------- 2/10 宿主 pgbouncer
echo ""
echo "【2/10】宿主 pgbouncer（127.0.0.1:6432）..."
if PGPASSWORD="$AUTHENTICATOR_PASSWORD" psql -h 127.0.0.1 -p 6432 -U authenticator -d app_db -tAc "SELECT 1" >/dev/null 2>&1; then
    log_pass "pgbouncer 连接成功（authenticator 角色可登录）"
else
    log_fail "pgbouncer 连接失败。检查: systemctl 状态 / userlist.txt / pg_hba"
fi

# ---------------------------------------------------------------- 3/10 PostgREST
echo ""
echo "【3/10】PostgREST OpenAPI（:3001）..."
LEN=$(curl -s --max-time 10 http://localhost:3001/ | wc -c)
if [ "${LEN:-0}" -gt 2000 ]; then
    log_pass "OpenAPI 完整（$LEN 字符）"
else
    log_fail "OpenAPI 异常（$LEN 字符，预期 >2000）。查看: docker logs app-postgrest"
fi

# ---------------------------------------------------------------- 4/10 Casdoor
echo ""
echo "【4/10】Casdoor（:8000）..."
if curl -sf --max-time 10 http://localhost:8000/api/health >/dev/null 2>&1; then
    log_pass "Casdoor healthy"
else
    log_fail "Casdoor 不可用。查看: docker logs app-casdoor"
fi

# ---------------------------------------------------------------- 5/10 APISIX Status
echo ""
echo "【5/10】APISIX Status API（:7085）..."
if curl -sf --max-time 5 http://localhost:7085/status 2>/dev/null | grep -q '"status":"ok"'; then
    log_pass "APISIX 就绪"
else
    log_fail "APISIX 未就绪。查看: docker logs app-apisix（etcd 是否先启动）"
fi

# ---------------------------------------------------------------- 6/10 Dashboard
echo ""
echo "【6/10】APISIX 内置 Dashboard（:9180/ui）..."
if curl -sf --max-time 5 http://localhost:9180/ui 2>/dev/null | grep -qi "html"; then
    log_pass "Dashboard UI 可访问（浏览器打开 http://localhost:9180/ui）"
else
    log_fail "Dashboard 不可访问。检查: config.yaml enable_admin_ui / 9180 端口映射"
fi

# ---------------------------------------------------------------- 7/10 路由清单
echo ""
echo "【7/10】路由清单（Admin API，预期 8 条）..."
ROUTE_COUNT=$(curl -s --max-time 5 http://localhost:9180/apisix/admin/routes \
    -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
    | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))' 2>/dev/null || echo "err")
if [ "$ROUTE_COUNT" = "8" ]; then
    log_pass "路由 8/8（jwks/login/refresh/sys/sales/inventory/rpc/catch-all）"
elif [ "$ROUTE_COUNT" = "err" ] || [ -z "$ROUTE_COUNT" ]; then
    log_fail "Admin API 不可用（检查 APISIX_ADMIN_KEY / 9180）"
else
    log_fail "路由数量异常: $ROUTE_COUNT（预期 8，运行 bash scripts/setup_apisix.sh 重建）"
fi

# ---------------------------------------------------------------- 8/10 登录链路
echo ""
echo "【8/10】登录链路（user_login_sso → JWT）..."
TOKEN=$(curl -s --max-time 10 -X POST http://localhost:9080/api/v1/rpc/user_login_sso \
    -H "Content-Type: application/json" \
    -d "{\"p_username\":\"${LOGIN_USER}\",\"p_password\":\"${LOGIN_PASS}\"}" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("access_token",""))' 2>/dev/null)
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    log_pass "登录成功，JWT 已签发（长度 ${#TOKEN}）"
else
    log_fail "登录失败。检查: PostgREST 连接 / 数据库迁移 / APISIX 路由 jwt-auth"
fi

# ---------------------------------------------------------------- 9/10 Syncer
echo ""
echo "【9/10】Policy Syncer..."
if docker inspect --format='{{.State.Status}}' policy-syncer 2>/dev/null | grep -q running; then
    SYNC_LOG=$(docker logs policy-syncer --tail 20 2>/dev/null | grep -ci "error\|failed\|❌" || true)
    if [ "${SYNC_LOG:-0}" = "0" ]; then
        log_pass "Syncer 运行中且近 20 行无错误"
    else
        log_fail "Syncer 运行中但日志含 ${SYNC_LOG} 处错误。查看: docker logs policy-syncer"
    fi
else
    log_fail "Syncer 容器未运行。查看: docker compose ps / docker compose build syncer"
fi

# ---------------------------------------------------------------- 10/10 无 docker PG 残留
echo ""
echo "【10/10】架构校验（无 docker PG 残留）..."
SERVICES=$(docker compose -f gateway/docker-compose.yml ps --format '{{.Service}}' 2>/dev/null || true)
if echo "$SERVICES" | grep -qE "^(pgsql|pgbouncer|casdoor-db)$"; then
    log_fail "检测到 docker PG 残留服务: $(echo "$SERVICES" | grep -E 'pgsql|pgbouncer|casdoor-db' | tr '\n' ' ')"
else
    log_pass "服务清单合规（仅网关侧服务）: $(echo "$SERVICES" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- 汇总
echo ""
echo "============================================"
echo "  验证结果: 通过 $PASS 项 / 失败 $FAIL 项"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    echo "  失败项:"
    for item in "${FAILED_ITEMS[@]}"; do
        echo "    ❌ $item"
    done
    echo ""
    echo "  排查指引: docs/审查文档/20号 §四/§九、22号 §四/§七"
    exit 1
else
    echo "  🎉 全部通过 — 系统就绪！"
    echo "  Dashboard: http://localhost:9180/ui"
    exit 0
fi
