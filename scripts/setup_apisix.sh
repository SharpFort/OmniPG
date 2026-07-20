#!/bin/bash
set -e

APISIX_ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
CASDOOR_URL="${CASDOOR_URL:-http://localhost:8000}"

echo "=== APISIX 初始化配置脚本 ==="
echo "APISIX Admin: ${APISIX_ADMIN_URL}"
echo "Casdoor URL:  ${CASDOOR_URL}"
echo ""

# 1. 写入 Casbin model.conf 到 etcd
echo "[1/6] 写入 Casbin model 配置..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/authz-casbin" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "[request_definition]\nr = sub, obj, act\n\n[policy_definition]\np = sub, obj, act\n\n[policy_effect]\ne = some(where (p.eft == allow))\n\n[matchers]\nm = regexMatch(r.sub, \"(^|,)\" + p.sub + \"($|,)\") && keyMatch2(r.obj, p.obj) && r.act == p.act",
    "policy": ""
  }'
echo "  ✅ 完成"

# 2. 获取 Casdoor JWKS
echo "[2/6] 获取 Casdoor JWKS 公钥..."
JWKS=$(curl -s "${CASDOOR_URL}/.well-known/jwks")
echo "  JWKS: ${JWKS:0:100}..."

# 3. 配置 jwt-auth
echo "[3/6] 配置 jwt-auth 插件..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/plugin_metadata/jwt-auth" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"algorithm\": \"RS256\", \"key\": \"${JWKS}\"}"
echo "  ✅ 完成"

# 4. 创建 JWKS 端点路由
echo "[4/6] 创建 JWKS 公钥端点路由..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/routes/jwks" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d @apisix/jwks_route.yaml
echo "  ✅ 完成"

# 5. 创建业务路由
echo "[5/6] 创建业务路由 (api-v1)..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/routes/api-v1" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/api/v1/*",
    "plugins": {
      "serverless-pre-function": {
        "phase": "rewrite",
        "functions": [
          "return function(conf, ctx)\n    local cjson = require(\"cjson\")\n    local base64 = require(\"ngx.base64\")\n    local auth_header = ngx.req.get_headers()[\"Authorization\"]\n    if auth_header and string.sub(auth_header, 1, 7) == \"Bearer \" then\n        local token = string.sub(auth_header, 8)\n        local parts = {}\n        for part in string.gmatch(token, \"[^.]+\") do\n            table.insert(parts, part)\n        end\n        if #parts >= 2 then\n            local payload_b64 = parts[2]\n            payload_b64 = string.gsub(payload_b64, \"-\", \"+\")\n            payload_b64 = string.gsub(payload_b64, \"_\", \"/\")\n            local rem = #payload_b64 % 4\n            if rem > 0 then\n                payload_b64 = payload_b64 .. string.rep(\"=\", 4 - rem)\n            end\n            local decoded = base64.decode_base64(payload_b64)\n            if decoded then\n                local status, jwt_json = pcall(cjson.decode, decoded)\n                if status and jwt_json and jwt_json.roles then\n                    local roles_str = table.concat(jwt_json.roles, \",\")\n                    ngx.req.set_header(\"X-User-Role\", roles_str)\n                    if jwt_json.user_id or jwt_json.sub then\n                        ngx.req.set_header(\"X-User-Id\", jwt_json.user_id or jwt_json.sub)\n                    end\n                    if jwt_json.tenant_id then\n                        ngx.req.set_header(\"X-Tenant-Id\", jwt_json.tenant_id)\n                    end\n                end\n            end\n        end\n    end\nend"
        ]
      },
      "jwt-auth": {},
      "authz-casbin": {
        "username": "X-User-Role"
      },
      "cors": {
        "allow_origins": "http://localhost:5173",
        "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
        "allow_headers": "Authorization,Content-Type,Accept-Profile,Prefer",
        "expose_headers": "Content-Range,Location",
        "allow_credential": true,
        "max_age": 1728000
      },
      "limit-req": {
        "rate": 100,
        "burst": 50,
        "key_type": "var",
        "key": "remote_addr",
        "rejected_code": 429,
        "rejected_msg": "{\"error\":\"rate_limit\",\"message\":\"Too many requests\"}"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "postgrest:3000": 1
      }
    }
  }'
echo "  ✅ 完成"

# 6. 创建 Casdoor Callback 路由
echo "[6/6] 创建 Casdoor Callback 路由..."
curl -s -X PUT "${APISIX_ADMIN_URL}/apisix/admin/routes/callback" \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "uri": "/cb",
    "plugins": {
      "proxy-rewrite": {
        "uri": "/"
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "casdoor:8000": 1
      }
    }
  }'
echo "  ✅ 完成"

echo ""
echo "=== APISIX 配置完成 ==="
echo "后续步骤："
echo " 1. 启动 Policy Syncer 容器"
echo " 2. 通过 Casdoor 控制台创建组织架构和应用"
echo " 3. 在 casbin_rule 中插入访问策略"
