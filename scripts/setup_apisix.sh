#!/bin/bash
set -e

APISIX_ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
CASDOOR_URL="${CASDOOR_URL:-http://localhost:8000}"

echo "=== APISIX 初始化配置脚本 ==="
echo "APISIX Admin: ${APISIX_ADMIN_URL}"
echo "Casdoor URL:  ${CASDOOR_URL}"
echo ""

# 1. 写入 Casbin model.conf 到 APISIX
echo "[1/3] 写入 Casbin model 配置..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/authz-casbin" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "[request_definition]\nr = sub, obj, act\n\n[policy_definition]\np = sub, obj, act\n\n[policy_effect]\ne = some(where (p.eft == allow))\n\n[matchers]\nm = regexMatch(r.sub, \"(^|,)\" + p.sub + \"($|,)\") && keyMatch2(r.obj, p.obj) && r.act == p.act",
    "policy": ""
  }'
echo "  ✅ 完成"

# 2. 获取 Casdoor JWKS
echo "[2/3] 获取 Casdoor JWKS 公钥..."
JWKS=$(curl -s "${CASDOOR_URL}/.well-known/jwks")
echo "  JWKS: ${JWKS:0:100}..."

# 3. 配置 jwt-auth
echo "[3/3] 配置 jwt-auth 插件..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/jwt-auth" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"algorithm\": \"RS256\", \"key\": \"${JWKS}\"}"
echo "  ✅ 完成"

echo ""
echo "=== APISIX 插件配置完成 ==="
echo "路由已由 apisix.yaml 静态加载，无需通过 Admin API 创建。"
echo "后续步骤："
echo "  1. 启动 Policy Syncer 容器"
echo "  2. 通过 Casdoor 控制台创建组织架构和应用"
echo "  3. 在 casbin_rule 中插入访问策略"
