#!/bin/bash
# =============================================================================
# APISIX 初始化脚本（Traditional 模式: Admin API + 内置 Dashboard）
# 职责:
#   [1/4] 等待 APISIX 就绪（Status API :7085）
#   [2/4] 配置 jwt-auth 插件元数据（HS256，密钥与 PGRST_JWT_SECRET 同源）
#   [3/4] 创建业务路由（与旧 apisix.yaml 语义一致，并修正 RPC 字段名校验）
#   [4/4] 配置全局 CORS 规则
# 用法:   bash scripts/setup_apisix.sh
# 依赖:   gateway/.env 已配置 APISIX_ADMIN_KEY 与 JWKS_JSON（cp .env.development gateway/.env）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 加载 gateway/.env（若调用方未显式设置环境变量）
if [ -f "$PROJECT_DIR/gateway/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/gateway/.env"
    set +a
fi

APISIX_ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-}"
APISIX_STATUS_URL="${APISIX_STATUS_URL:-http://localhost:7085}"

[ -n "$APISIX_ADMIN_KEY" ] || { echo "❌ APISIX_ADMIN_KEY 未设置（检查 gateway/.env）"; exit 1; }
[ -n "${JWKS_JSON:-}" ]    || { echo "❌ JWKS_JSON 未设置（检查 gateway/.env）"; exit 1; }

AUTH="X-API-KEY: ${APISIX_ADMIN_KEY}"
CT="Content-Type: application/json"

# ---------------------------------------------------------------- 1/4 就绪
echo "[1/4] 等待 APISIX 就绪（Status API :7085）..."
for i in $(seq 1 30); do
    if curl -sf "$APISIX_STATUS_URL/status" 2>/dev/null | grep -q '"status":"ok"'; then
        echo "  ✅ APISIX 就绪（等待 ${i}x2s）"
        break
    fi
    if [ "$i" = "30" ]; then
        echo "  ❌ APISIX 未就绪。排查: docker compose ps / docker logs app-apisix / etcd 是否启动"
        exit 1
    fi
    sleep 2
done

# ---------------------------------------------------------------- 2/4 jwt-auth 元数据
echo "[2/4] 配置 jwt-auth 插件元数据（HS256）..."
# 从 JWKS_JSON 提取 base64 密钥（与 PGRST_JWT_SECRET 的 k 字段同源）
JWT_K=$(echo "$JWKS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['keys'][0]['k'])" 2>/dev/null \
        || echo "$JWKS_JSON" | sed -n 's/.*"k":"\([^"]*\)".*/\1/p')
[ -n "$JWT_K" ] || { echo "  ❌ 无法从 JWKS_JSON 提取 k 字段"; exit 1; }

RESP=$(curl -s -X PUT "$APISIX_ADMIN_URL/apisix/admin/plugin_metadata/jwt-auth" \
    -H "$AUTH" -H "$CT" \
    -d "{\"algorithm\":\"HS256\",\"key\":\"${JWT_K}\",\"base64_secret\":true}")
echo "$RESP" | grep -q '"key"' && echo "  ✅ jwt-auth 元数据已写入" \
    || { echo "  ❌ 写入失败: $RESP"; exit 1; }

# ---------------------------------------------------------------- 3/4 业务路由
echo "[3/4] 创建业务路由..."
put_route() { # put_route <id> <json-body>
    local id="$1" body="$2" r
    r=$(curl -s -X PUT "$APISIX_ADMIN_URL/apisix/admin/routes/${id}" -H "$AUTH" -H "$CT" -d "$body")
    echo "$r" | grep -q '"key"' && echo "  ✅ route: ${id}" \
        || { echo "  ❌ route ${id} 失败: ${r}"; exit 1; }
}

# JWKS 公钥端点（公开，供 jwks 校验；上游为 Casdoor）
put_route jwks '{"uri":"/.well-known/jwks","upstream":{"type":"roundrobin","nodes":{"app-casdoor:8000":1}},"priority":100}'

# 登录（公开；字段名校验与 user_login_sso(p_username,p_password) 签名一致）
put_route user_login_sso '{"uri":"/rpc/user_login_sso","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":90,"plugins":{"request-validation":{"body_schema":{"type":"object","required":["p_username","p_password"],"properties":{"p_username":{"type":"string","minLength":3},"p_password":{"type":"string","minLength":6}}}}}}'

# 刷新令牌（公开；字段名与 refresh_token_rtr(p_old_rt) 签名一致）
put_route refresh_token_rtr '{"uri":"/rpc/refresh_token_rtr","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":90,"plugins":{"request-validation":{"body_schema":{"type":"object","required":["p_old_rt"],"properties":{"p_old_rt":{"type":"string","minLength":16}}}}}}'

# 模块路由（jwt-auth 保护 + 路径重写）
put_route api_v1_public '{"uri":"/api/v1/sys/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":50,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/sys/(.*)","/api_v1_public/$1"]},"jwt-auth":{}}}'
put_route api_v1_sales '{"uri":"/api/v1/sales/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":20,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/sales/(.*)","/api_v1_sales/$1"]},"jwt-auth":{}}}'
put_route api_v1_inventory '{"uri":"/api/v1/inventory/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":20,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/inventory/(.*)","/api_v1_inventory/$1"]},"jwt-auth":{}}}'

# 其余 RPC（jwt-auth 保护）
put_route rpc_all '{"uri":"/rpc/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":40,"plugins":{"jwt-auth":{}}}'

# 兜底路由（jwt-auth 保护；未匹配请求进入 PostgREST 由其返回 404）
put_route catch_all '{"uri":"/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":10,"plugins":{"jwt-auth":{}}}'

# ---------------------------------------------------------------- 4/4 全局 CORS
echo "[4/4] 配置全局 CORS 规则..."
RESP=$(curl -s -X PUT "$APISIX_ADMIN_URL/apisix/admin/global_rules/1" -H "$AUTH" -H "$CT" \
    -d '{"plugins":{"cors":{"allow_origins":"*","allow_methods":"GET,POST,PUT,PATCH,DELETE,OPTIONS","allow_headers":"Authorization,Content-Type,X-Requested-With","expose_headers":"X-Total-Count,Content-Range","max_age":3600,"allow_credentials":true}}}')
echo "$RESP" | grep -q '"key"' && echo "  ✅ 全局 CORS 规则已写入" \
    || { echo "  ❌ 写入失败: $RESP"; exit 1; }

echo ""
echo "=== APISIX 初始化完成 ==="
echo "  Dashboard:   http://localhost:9180/ui  （Admin Key: ${APISIX_ADMIN_KEY:0:6}...）"
echo "  Admin API:   http://localhost:9180/apisix/admin"
echo "  Status API:  http://localhost:7085/status"
ROUTE_COUNT=$(curl -s "$APISIX_ADMIN_URL/apisix/admin/routes" -H "$AUTH" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))' 2>/dev/null || echo "?")
echo "  路由数量:    ${ROUTE_COUNT}"
