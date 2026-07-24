#!/bin/bash
set -e

CASDOOR_URL="${CASDOOR_URL:-http://localhost:8000}"
APISIX_ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6}"

echo "=== Casdoor 集成配置脚本 ==="
echo "APISIX Admin: ${APISIX_ADMIN_URL}"
echo "Casdoor URL:  ${CASDOOR_URL}"
echo ""

# 1. 获取 Casdoor JWKS
echo "[1/4] 获取 Casdoor JWKS..."
JWKS=$(curl -s "${CASDOOR_URL}/.well-known/jwks")
if [ -z "$JWKS" ]; then
  echo "  ❌ 无法获取 JWKS，请确认 Casdoor 已启动"
  exit 1
fi
echo "  JWKS: ${JWKS:0:100}..."

# 2. 配置 APISIX jwt-auth
echo "[2/4] 配置 APISIX jwt-auth..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/jwt-auth" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"algorithm\": \"RS256\", \"key\": \"${JWKS}\"}"
echo "  ✅ 完成"

# 3. 配置 APISIX authz-casdoor
echo "[3/4] 配置 APISIX authz-casdoor..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/casdoor" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "casdoor_endpoint": "http://localhost:8000",
    "client_id": "zero-backend-app",
    "client_secret": "YOUR_CLIENT_SECRET",
    "callback_url": "http://localhost:9000/cb"
  }'
echo "  ✅ 完成"

# 4. 创建 Casdoor SDK 配置路由
echo "[4/4] 创建 Casdoor SDK 配置路由..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/routes/casdoor-sdk-config" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/.well-known/casdoor-config",
    "plugins": {
      "mocking": {
        "content_type": "application/json",
        "response_status": 200,
        "response_example": |
          {
            "serverUrl": "http://localhost:8000",
            "clientId": "zero-backend-app",
            "organizationName": "built-in",
            "appName": "zero-backend-rbac",
            "redirectPath": "/cb",
            "scope": "read"
          }
      }
    }
  }'
echo "  ✅ 完成"

echo ""
echo "=== Casdoor 集成完成 ==="
echo "后续步骤："
echo " 1. 在 Casdoor 控制台创建应用 (appName: zero-backend-rbac)"
echo " 2. 更新 client_secret 为真实值"
echo " 3. 配置前端 SDK 使用 /.well-known/casdoor-config 端点"
