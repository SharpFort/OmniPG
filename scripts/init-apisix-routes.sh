#!/bin/bash
# APISIX route init - run inside WSL2
set -euo pipefail

ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
JWKS_JSON="${JWKS_JSON:-{\"keys\":[{\"kty\":\"oct\",\"kid\":\"dev-hs256\",\"alg\":\"HS256\",\"k\":\"c2VjcmV0X2RldmVsb3BtZW50X2tleV9hdF9sZWFzdF9zZXZlbl9jaGFyYWN0ZXJzIQ==\"}]}}"
AUTH="X-API-KEY: ${ADMIN_KEY}"

echo "[1] Wait APISIX..."
for i in $(seq 1 15); do
  curl -sf http://localhost:7085/status 2>/dev/null | grep -q '"status":"ok"' && break
  sleep 1
done
echo "  OK"

echo "[2] jwt-auth metadata..."
# JWK base64 key (from JWKS_JSON k field)
JWK="c2VjcmV0X2RldmVsb3BtZW50X2tleV9hdF9sZWFzdF9zZXZlbl9jaGFyYWN0ZXJzIQ=="
curl -s -X PUT http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"algorithm\":\"HS256\",\"key\":\"${JWK}\",\"base64_secret\":true}"
echo "  OK"

echo "[3] Global CORS..."
curl -s -X PUT http://localhost:9180/apisix/admin/global_rules/1 \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"plugins":{"cors":{"allow_origins":"*","allow_methods":"GET,POST,PUT,PATCH,DELETE,OPTIONS","allow_headers":"Authorization,Content-Type,X-Requested-With","expose_headers":"X-Total-Count,Content-Range","max_age":3600,"allow_credentials":true}}}'
echo "  OK"

echo "[4] Routes..."
put() { curl -s -X PUT "http://localhost:9180/apisix/admin/routes/$1" -H "$AUTH" -H 'Content-Type: application/json' -d "$2"; }

put jwks '{"uri":"/.well-known/jwks","upstream":{"type":"roundrobin","nodes":{"app-casdoor:8000":1}},"priority":100}'
put user_login_sso '{"uri":"/rpc/user_login_sso","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":90,"plugins":{"request-validation":{"body_schema":{"type":"object","required":["p_username","p_password"],"properties":{"p_username":{"type":"string","minLength":3},"p_password":{"type":"string","minLength":6}}}}}}'
put refresh_token_rtr '{"uri":"/rpc/refresh_token_rtr","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":90}'
put api_v1_sys '{"uri":"/api/v1/sys/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":50,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/sys/(.*)","/api_v1_sys/$1"]},"jwt-auth":{}}}'
put api_v1_sales '{"uri":"/api/v1/sales/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":20,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/sales/(.*)","/api_v1_sales/$1"]},"jwt-auth":{}}}'
put api_v1_inventory '{"uri":"/api/v1/inventory/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":20,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/inventory/(.*)","/api_v1_inventory/$1"]},"jwt-auth":{}}}'
put rpc_all '{"uri":"/rpc/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":40,"plugins":{"jwt-auth":{}}}'
put catch_all '{"uri":"/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":10,"plugins":{"jwt-auth":{}}}'

echo
COUNT=$(curl -s http://localhost:9180/apisix/admin/routes -H "$AUTH" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))')
echo "  ${COUNT} routes created"
echo "  Dashboard: http://localhost:9180/ui"
