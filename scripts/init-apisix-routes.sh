#!/bin/bash
# APISIX route init — Logto 版（2026-08-19 起为唯一部署链路由脚本；
#   Makefile dev / deploy-all.sh / deploy-gateway.yml 均已接入；Casdoor 时代 setup_apisix.sh 已删除）
# 变更: jwt-auth HS256→RS256（Logto JWKS）；移除 Casdoor 路由；
#       新增 /logto/* 同源代理；新增 /rpc/webhook_logto（webhook 接收入口）
#       新增 POST /rpc/ensure_user（JIT 建档，authenticated 调）
set -euo pipefail

ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
AUTH="X-API-KEY: ${ADMIN_KEY}"

# ---------------------------------------------------------------------------
# [0] 预先清理 Casdoor 时代旧路由（幂等：DELETE 不存在路由 204）
#     含 api_v1_sys（027 schema 重命名后的残留，指向已删 schema）
# ---------------------------------------------------------------------------
echo "[0] Cleanup Casdoor routes..."
for rid in jwks user_login_sso refresh_token_rtr casdoor_proxy api_v1_sys api_v1_sales api_v1_inventory; do
  curl -s -X DELETE "http://localhost:9180/apisix/admin/routes/${rid}" -H "$AUTH" || true
done
echo "  OK"

# ---------------------------------------------------------------------------
# [1] 等待 APISIX 就绪
# ---------------------------------------------------------------------------
echo "[1] Wait APISIX..."
for i in $(seq 1 15); do
  curl -sf http://localhost:7085/status 2>/dev/null | grep -q '"status":"ok"' && break
  sleep 1
done
echo "  OK"

# ---------------------------------------------------------------------------
# [2] 获取 Logto JWKS（RS256 公钥）并注入 jwt-auth 元数据
#     Logto OIDC discovery: /.well-known/openid-configuration → jwks_uri
# ---------------------------------------------------------------------------
echo "[2] Fetch Logto JWKS..."
LOGTO_OIDC="http://localhost:3001/oidc/.well-known/openid-configuration"
JWKS_URI=$(curl -sf "$LOGTO_OIDC" | ${PYTHON:-python3} -c "import sys,json; print(json.load(sys.stdin)['jwks_uri'])" 2>/dev/null || echo "http://localhost:3001/oidc/jwks")
echo "  JWKS URI: $JWKS_URI"
JWKS_JSON=$(curl -sf "$JWKS_URI")
if [ -z "$JWKS_JSON" ]; then
  echo "  ERROR: Cannot fetch Logto JWKS; is Logto running at localhost:3001?"
  exit 2
fi
echo "  JWKS fetched OK"

# jwt-auth 插件元数据：RS256 + JWKS JSON（APISIX key 字段接受 JSON 字符串）
curl -s -X PUT http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"algorithm\":\"RS256\",\"key\":$(echo "$JWKS_JSON" | ${PYTHON:-python3} -c 'import sys,json; print(json.dumps(json.dumps(json.load(sys.stdin))))')}"
echo "  jwt-auth → RS256 + Logto JWKS"

# ---------------------------------------------------------------------------
# [3] Global CORS
# ---------------------------------------------------------------------------
echo "[3] Global CORS..."
curl -s -X PUT http://localhost:9180/apisix/admin/global_rules/1 \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"plugins":{"cors":{"allow_origins":"*","allow_methods":"GET,POST,PUT,PATCH,DELETE,OPTIONS","allow_headers":"Authorization,Content-Type,X-Requested-With,logto-signature-sha-256","expose_headers":"X-Total-Count,Content-Range","max_age":3600,"allow_credentials":true}}}'
echo "  OK"

# ---------------------------------------------------------------------------
# [4] Routes
# ---------------------------------------------------------------------------
echo "[4] Routes..."
put() { curl -s -X PUT "http://localhost:9180/apisix/admin/routes/$1" -H "$AUTH" -H 'Content-Type: application/json' -d "$2"; }

# 4.1 Logto JWKS 代理（前端 SDK / OIDC 客户端拉取公钥）
put logto_jwks '{"uri":"/.well-known/jwks","upstream":{"type":"roundrobin","nodes":{"app-logto:3001":1}},"priority":100}'

# 4.2 Logto 同源代理 /logto/*（前端 SDK endpoint，CORS 规避；若配置 Logto CORS 则可去掉此路由）
put logto_proxy '{"uri":"/logto/*","upstream":{"type":"roundrobin","nodes":{"app-logto:3001":1}},"priority":60,"plugins":{"proxy-rewrite":{"regex_uri":["^/logto/(.*)","/$1"]}}}'

# 4.3 Webhook 接收入口 — /rpc/webhook_logto（POST，web_anon 可调，无 jwt-auth）
#     验签由 APISIX serverless-pre-function 完成（HMAC-SHA256(rawBody) vs logto-signature-sha-256）
#     注意：不可叠加 request-validation（其 JSON 重排会破坏 rawBody 签名）
#     注意：大 body（>client_body_buffer_size）会落临时文件，须 get_body_file() 回退读取
WEBHOOK_SIGNING_KEY="${LOGTO_WEBHOOK_SIGNING_KEY:-}"
if [ -z "$WEBHOOK_SIGNING_KEY" ]; then
  echo "  ✗✗ 缺少 LOGTO_WEBHOOK_SIGNING_KEY（gateway/.env）——webhook 验签 fail-closed（N15）：拒绝部署" >&2
  exit 1
fi
export WEBHOOK_SIGNING_KEY
# 用 python 生成路由 JSON（避免 bash 内嵌 Lua 转义地狱）
cat > .webhook_verify.lua <<'LUA'
return function(conf, ctx)
  local resty_hmac = require('resty.openssl.hmac')
  local resty_str = require('resty.string')
  -- APISIX serverless-pre-function: 函数 conf 参数 = 整个插件配置对象，
  -- signing_key 放在 schema 允许的 conf 字段内（顶层未知字段会被 APISIX 丢弃）
  local key = (conf.conf and conf.conf.signing_key) or conf.signing_key
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  if not body then
    local file = ngx.req.get_body_file()
    if file then
      local f = assert(io.open(file, 'rb'))
      body = f:read('*a')
      f:close()
    end
  end
  body = body or ''
  local sig = ngx.var.http_logto_signature_sha_256 or ''
  if sig == '' then return ngx.exit(401) end
  local hmac = resty_hmac.new(key, 'sha256')
  hmac:update(body)
  local expected = resty_str.to_hex(hmac:final())
  if expected ~= sig then
    ngx.log(ngx.ERR, 'webhook signature mismatch: expected=' .. expected .. ' got=' .. sig)
    return ngx.exit(401)
  end
end
LUA
WEBHOOK_LUA="$(cat .webhook_verify.lua)"
rm -f .webhook_verify.lua
export WEBHOOK_LUA
WEBHOOK_JSON="$(${PYTHON:-python3} -c '
import json, os
lua_fn = os.environ["WEBHOOK_LUA"]
route = {
    "uri": "/rpc/webhook_logto",
    "upstream": {"type": "roundrobin", "nodes": {"app-postgrest:3000": 1}},
    "priority": 95,
    "methods": ["POST"],
    "plugins": {
        "serverless-pre-function": {
            "phase": "access",
            "functions": [lua_fn],
            "conf": {"signing_key": os.environ["WEBHOOK_SIGNING_KEY"]},
        }
    },
}
print(json.dumps(route))
')"
put webhook_logto "$WEBHOOK_JSON"

# 4.4 JIT 建档 — /rpc/ensure_user（POST，需要 JWT auth）
put ensure_user '{"uri":"/rpc/ensure_user","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":80,"methods":["POST"],"plugins":{"jwt-auth":{"key_claim_name":"sub"}}}'

# 4.5 API v1 路由（业务 API，需 jwt-auth + proxy-rewrite 去掉前缀映射 schema）
put api_v1_platform '{"uri":"/api/v1/platform/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":50,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/platform/(.*)","/$1"]},"jwt-auth":{"key_claim_name":"sub"}}}'
# （2026-08-15: api_v1_sales / api_v1_inventory 测试模块退役，路由移除；后续模块按需重建）

# 4.6 RPC 路由（所有带 jwt-auth 的 RPC，匹配 /rpc/* 但排除 webhook_logto — 确保 webhook_logto 优先级更高）
put rpc_all '{"uri":"/rpc/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":40,"plugins":{"jwt-auth":{"key_claim_name":"sub"}}}'

# 4.7 Catch-all（AuthN 准入）
put catch_all '{"uri":"/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":10,"plugins":{"jwt-auth":{"key_claim_name":"sub"}}}'

# ---------------------------------------------------------------------------
# [5] 汇总
# ---------------------------------------------------------------------------
echo
COUNT=$(curl -s http://localhost:9180/apisix/admin/routes -H "$AUTH" | ${PYTHON:-python3} -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))')
echo "  ${COUNT} routes configured"
echo "  Dashboard: http://localhost:9180/ui"
echo "  Logto OIDC: http://localhost:9080/logto/oidc/.well-known/openid-configuration"
