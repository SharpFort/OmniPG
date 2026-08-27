#!/bin/bash
# =============================================================================
# OmniPG 全栈验证脚本（一键运行）
# 用法:   bash scripts/verify-stack.sh
# 环境:   WSL2 Ubuntu（Pigsty 宿主 + Docker Desktop），在项目根目录执行
# 覆盖:   docs/审查文档/22号 §七 验证清单（8 项；Casdoor/Syncer 已于 2026-08-19 退役移除）
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
echo "【0/8】依赖预检..."
DEPS_OK=1
for t in docker curl psql; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "  ✅ $t"
    else
        echo "  ❌ $t 缺失"
        DEPS_OK=0
    fi
done
# JSON 解析器: python3 优先，python 兜底（Windows 上可能只有 python）
PYTHON_BIN=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys,json" >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v "$cand")"
        echo "  ✅ JSON 解析器: $cand ($PYTHON_BIN)"
        break
    fi
done
if [ -z "$PYTHON_BIN" ]; then
    echo "  ❌ python3/python 均不可用（需支持 json 模块）"
    DEPS_OK=0
fi
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
echo "【1/10】网络链路（容器 → 宿主 pgBouncer 6432）..."
NET=$(docker network ls --format '{{.Name}}' | grep -E 'app-net$' | head -1)
if [ -z "$NET" ]; then
    log_fail "找不到 app-net 网络（是否已 docker compose up -d？）"
else
    if docker run --rm --network "$NET" --add-host host.docker.internal:host-gateway \
        alpine sh -c 'nc -z -w3 host.docker.internal 6432' >/dev/null 2>&1; then
        log_pass "容器→宿主 pgBouncer(6432) 可达（网络: $NET）"
    else
        log_fail "容器→宿主 pgBouncer(6432) 不可达。检查: Win11 mirrored / scripts/wsl-portproxy.ps1"
    fi
fi

# ---------------------------------------------------------------- 2/10 宿主 pgBouncer
echo ""
echo "【2/10】宿主 pgBouncer（127.0.0.1:6432）..."
if PGPASSWORD="$AUTHENTICATOR_PASSWORD" psql -h 127.0.0.1 -p 6432 -U authenticator -d app_db -tAc "SELECT 1" >/dev/null 2>&1; then
    log_pass "pgBouncer 连接成功（authenticator 角色可登录；PostgREST 经 6432）"
else
    log_fail "pgBouncer 连接失败。检查: userlist.txt 是否已重载（pkill pgbouncer && sudo -u postgres /usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer.ini &）/ systemctl 状态 / pg_hba"
fi

# ---------------------------------------------------------------- 3/10 PostgREST
echo ""
echo "【3/10】PostgREST OpenAPI（:3100）..."
LEN=$(curl -s --max-time 10 http://localhost:3100/ | wc -c)
if [ "${LEN:-0}" -gt 2000 ]; then
    log_pass "OpenAPI 完整（$LEN 字符）"
else
    log_fail "OpenAPI 异常（$LEN 字符，预期 >2000）。查看: docker logs app-postgrest"
fi

# ---------------------------------------------------------------- 4/8 APISIX Status
echo ""
echo "【4/8】APISIX Status API（:7085，仅本机回环）..."
if curl -sf --max-time 5 http://localhost:7085/status 2>/dev/null | grep -q '"status":"ok"'; then
    log_pass "APISIX 就绪"
else
    log_fail "APISIX 未就绪。查看: docker logs app-apisix（etcd 是否先启动）"
fi

# ---------------------------------------------------------------- 5/8 Dashboard
echo ""
echo "【5/8】APISIX 内置 Dashboard（:9180/ui）..."
if curl -sf --max-time 5 http://localhost:9180/ui 2>/dev/null | grep -qi "html"; then
    log_pass "Dashboard UI 可访问（浏览器打开 http://localhost:9180/ui；仅内网管理）"
else
    log_fail "Dashboard 不可访问。检查: config.yaml enable_admin_ui / 9180 映射（仅内网）"
fi

# ---------------------------------------------------------------- 6/8 路由清单
echo ""
echo "【6/8】路由清单（Admin API，预期 7 条）..."
ROUTE_COUNT=$(curl -s --max-time 5 http://localhost:9180/apisix/admin/routes \
    -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
    | "$PYTHON_BIN" -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))' 2>/dev/null || echo "err")
if [ "$ROUTE_COUNT" = "7" ]; then
    log_pass "路由 7/7（logto_jwks/logto_proxy/webhook_logto/ensure_user/api_v1_platform/rpc_all/catch_all）"
elif [ "$ROUTE_COUNT" = "err" ] || [ -z "$ROUTE_COUNT" ]; then
    log_fail "Admin API 不可用（检查 APISIX_ADMIN_KEY / 9180 内网可达）"
else
    log_fail "路由数量异常: $ROUTE_COUNT（预期 7，运行 bash scripts/init-apisix-routes.sh 重建）"
fi

# ---------------------------------------------------------------- 7/8 Logto OIDC
echo ""
echo "【7/8】Logto OIDC Discovery（:3001）..."
if curl -sf --max-time 10 http://localhost:3001/oidc/.well-known/openid-configuration 2>/dev/null | grep -q 'jwks_uri'; then
    log_pass "Logto OIDC Discovery 正常（完整登录链路验证见 scripts/e2e-test.sh）"
else
    log_fail "Logto OIDC 不可用。检查: docker logs app-logto / gateway/.env"
fi

# ---------------------------------------------------------------- 8/8 无 docker PG 残留
echo ""
echo "【8/8】架构校验（无 docker PG 残留）..."
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