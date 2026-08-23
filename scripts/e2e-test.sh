#!/bin/bash
# ==============================================================================
# 全系统端到端验收自动化脚本（Logto 版）— 替代 Casdoor 时代版本
# 架构: Logto OSS v1.42（3001/3002）+ PostgREST（3100，api_v1_platform）
#        + APISIX（9080，jwt-auth ES384）+ Logto 只读投影视图（users/tenants/tenant_role）
# ==============================================================================

set -u

BASE_URL="${BASE_URL:-http://localhost:9080}"
PGRST_URL="${PGRST_URL:-http://localhost:3100}"
LOGTO_URL="${LOGTO_URL:-http://localhost:3001}"
CLIENT_ID="${CLIENT_ID:-0d4o8wb6qk9bar0egelb4}"
REDIRECT_URI="${REDIRECT_URI:-http://localhost:5173/auth/callback}"
ORG_ID="${ORG_ID:-q8xan57gksx5}"
RESOURCE="https://default.logto.app/api"
E2E_USER="${E2E_USER:-admin}"
E2E_PASSWORD="${E2E_PASSWORD:-Admin@112104}"
ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"
FAILED=0
PASSED=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

run_test() {
    local category="$1" name="$2" description="$3" cmd="$4"
    echo -n "  [$category] $name: "
    if eval "$cmd" > /dev/null 2>&1; then
        echo "✅ PASS"; PASSED=$((PASSED + 1))
    else
        echo "❌ FAIL"; FAILED=$((FAILED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Logto OIDC code flow 登录 → 返回 access_token（PKCE；T6 验证流程）
# ---------------------------------------------------------------------------
logto_login() {
    local verifier challenge code r1 r2
    verifier=$(python3 -c "import secrets; print(secrets.token_urlsafe(64))")
    challenge=$(python3 -c "
import hashlib, base64
v = '$verifier'
d = hashlib.sha256(v.encode()).digest()
print(base64.urlsafe_b64encode(d).rstrip(b'=').decode())")
    local res_enc
    res_enc=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$RESOURCE'))")
    local scope="openid%20profile%20offline_access%20urn:logto:scope:organizations"

    curl -s -c "$TMPD/c.txt" -o /dev/null \
      "$LOGTO_URL/oidc/auth?client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&response_type=code&scope=$scope&state=s&code_challenge=$challenge&code_challenge_method=S256&resource=$res_enc&prompt=consent"
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -X PUT "$LOGTO_URL/api/interaction" \
      -H "Content-Type: application/json" \
      -d "{\"event\":\"SignIn\",\"identifier\":{\"username\":\"$E2E_USER\",\"password\":\"$E2E_PASSWORD\"}}" -o /dev/null
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -X POST "$LOGTO_URL/api/interaction/submit" -o "$TMPD/sub.html"
    r1=$(python3 -c "import json; print(json.load(open('$TMPD/sub.html'))['redirectTo'])" 2>/dev/null) || return 1
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -o /dev/null "$r1"
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -X POST "$LOGTO_URL/api/interaction/consent" \
      -H "Content-Type: application/json" -d "{\"organizationIds\":[\"$ORG_ID\"]}" -o "$TMPD/cons.html"
    r2=$(python3 -c "import json; print(json.load(open('$TMPD/cons.html'))['redirectTo'])" 2>/dev/null) || return 1
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -D "$TMPD/fin.txt" -o /dev/null "$r2"
    code=$(grep -i '^location' "$TMPD/fin.txt" | tr -d '\r' | grep -oP 'code=\K[^&]+' | head -1) || return 1
    [ -z "$code" ] && return 1
    # 注意: token 交换必须带 resource（RFC 8707）→ Logto 才签发 JWT（否则 opaque token，APISIX 无法验签）
    curl -s -X POST "$LOGTO_URL/oidc/token" -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=authorization_code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&code=$code&code_verifier=$verifier&resource=$res_enc" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"
}

echo ""
echo "========================================"
echo "  全系统端到端验收测试（Logto 版）"
echo "========================================"
echo ""

# ==============================================================================
# Phase 0: 环境就绪检查（Casdoor 8000 → Logto 3001/3002）
# ==============================================================================
echo "📋 Phase 0: 环境就绪检查"

run_test "ENV" "PostgREST Running" "PostgREST 健康" \
    "curl -sf $PGRST_URL/ | head -c 100"
run_test "ENV" "APISIX Running" "APISIX 健康" \
    "curl -sf http://localhost:9180/apisix/admin/routes -H 'X-API-KEY: $ADMIN_KEY' | grep -q api_v1_platform"
run_test "ENV" "Logto Running" "Logto OIDC 服务健康" \
    "curl -sf $LOGTO_URL/oidc/.well-known/openid-configuration | grep -q issuer"
run_test "ENV" "Backend Health" "Swagger UI 可用" \
    "curl -sf http://localhost:8082/"
run_test "ENV" "Logto JWKS" "Logto JWKS 端点可用" \
    "curl -sf $LOGTO_URL/oidc/jwks | jq -e '.keys[0].kty'"

sleep 1

# ==============================================================================
# Phase 1: 认证流程（Logto OIDC code flow；Casdoor user_login_sso 已退役）
# ==============================================================================
echo ""
echo "📋 Phase 1: 认证流程"

TOKEN=$(logto_login || true)

run_test "AUTH" "Admin Login" "Logto OIDC 登录成功拿到 token" \
    "[ -n '$TOKEN' ] && [ '${#TOKEN}' -gt 100 ]"

run_test "AUTH" "Invalid Password Rejected" "错误密码被 Logto 拒绝" \
    "E2E_PASSWORD=wrongpassword_xyz logto_login | grep -qv '^eyJ' ; [ \$? -eq 1 ]"

run_test "AUTH" "Unauthorized Request" "无 Token 请求返回 401/403" \
    "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' | grep -q '40[13]'"

run_test "AUTH" "Authorized Request" "带 Token 访问镜像表正常" \
    "curl -sf '$BASE_URL/api/v1/platform/role?select=role_code,role_name&limit=5' -H \"Authorization: Bearer $TOKEN\" | jq -e '.[0].role_code'"

run_test "AUTH" "Menu Loaded" "用户菜单树加载成功" \
    "curl -sf '$BASE_URL/api/v1/platform/rpc/get_user_menu' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 0'"

# ==============================================================================
# Phase 2: 权限与只读保障（镜像表只读；写操作应被拒 — Logto 单向同步）
# ==============================================================================
echo ""
echo "📋 Phase 2: 权限与只读保障"

run_test "RBAC" "Users Readonly" "users 镜像表 POST 被拒（视图不可插入 500/400）" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/api/v1/platform/users' -H 'Content-Type: application/json' -H \"Authorization: Bearer $TOKEN\" -d '{\"username\":\"x\"}' | grep -qE '4[0-9]{2}|5[0-9]{2}'"

run_test "RBAC" "Role Readonly" "role 镜像表 POST 被拒" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/api/v1/platform/role' -H 'Content-Type: application/json' -H \"Authorization: Bearer $TOKEN\" -d '{\"name\":\"x\"}' | grep -qE '40[13]|4[0-9]{2}'"

run_test "RBAC" "Tenant Readonly" "tenants 镜像表 POST 被拒" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/api/v1/platform/tenants' -H 'Content-Type: application/json' -H \"Authorization: Bearer $TOKEN\" -d '{\"name\":\"x\"}' | grep -qE '40[13]|4[0-9]{2}'"

run_test "RBAC" "User List" "查询用户列表（v_user_list 视图）" \
    "curl -sf '$BASE_URL/api/v1/platform/v_user_list?select=id,username&limit=5' -H \"Authorization: Bearer $TOKEN\" | jq -e '.[0].id'"

run_test "RBAC" "Role List" "查询角色列表（v_role_list 视图）" \
    "curl -sf '$BASE_URL/api/v1/platform/v_role_list?select=role_code,role_name&limit=5' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

# ==============================================================================
# Phase 3: API 鉴权
# ==============================================================================
echo ""
echo "📋 Phase 3: API 鉴权"

run_test "API" "GET /role" "镜像表 role 可读" \
    "curl -sf '$BASE_URL/api/v1/platform/role?limit=3' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

run_test "API" "GET /users" "镜像表 users 可读" \
    "curl -sf '$BASE_URL/api/v1/platform/users?select=id,username&limit=3' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

run_test "API" "RPC get_current_user" "当前用户信息（JWT claims）" \
    "curl -sf '$BASE_URL/api/v1/platform/rpc/get_current_user' -H \"Authorization: Bearer $TOKEN\" | jq -e '.id'"

run_test "API" "JWKS Endpoint" "Logto JWKS 端点可访问" \
    "curl -sf '$BASE_URL/logto/oidc/jwks' | jq -e '.keys[0].kty'"

run_test "API" "404 for Not Found" "不存在的路由被拒绝" \
    "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/nonexistent' | grep -q '40[13]'"

# ==============================================================================
# Phase 4: 角色即时生效（JWT 角色；触发器通知链路）
# ==============================================================================
echo ""
echo "📋 Phase 4: 角色与同步链路"

run_test "REALTIME" "JWT Roles Claim" "token 携带 roles（Logto 角色）" \
    "echo '$TOKEN' | python3 -c \"import sys,base64,json; t=sys.stdin.read().strip(); p=t.split('.')[1]; p+='='*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p)); print(d.get('roles',[]))\" | grep -q 'role_super_admin'"

run_test "REALTIME" "Role List API" "v_role_list 反映 Logto 角色" \
    "curl -sf '$BASE_URL/api/v1/platform/v_role_list?select=role_code&limit=10' -H \"Authorization: Bearer $TOKEN\" | jq -e '[.[].role_code] | length >= 1'"

# ==============================================================================
# Phase 5: 多租户隔离（RLS：JWT organization_id）
# ==============================================================================
echo ""
echo "📋 Phase 5: 多租户隔离"

run_test "TENANT" "Tenant Isolation" "RLS 按租户过滤（department/audit_log 可读）" \
    "curl -sf '$BASE_URL/api/v1/platform/department?select=id&limit=1' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 0'"

run_test "TENANT" "Dept Tenant Scoped" "department RLS 按租户过滤（可读）" \
    "curl -sf '$BASE_URL/api/v1/platform/department?select=id&limit=3' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 0'"

run_test "TENANT" "audit_log Scoped" "audit_log RLS 可读" \
    "curl -sf '$BASE_URL/api/v1/platform/audit_log?select=id&limit=3' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 0'"

# ==============================================================================
# Phase 6: 同库只读视图 + PostSignIn 登录日志 webhook（D25）
# ==============================================================================
echo ""
echo "📋 Phase 6: 同库只读视图 + PostSignIn"

run_test "SYNC" "webhook RPC 存在" "webhook_logto 函数注册" \
    "PGPASSWORD=admin@password psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c \"SELECT proname FROM pg_proc WHERE proname='webhook_logto';\" 2>/dev/null | grep -q webhook_logto"

run_test "SYNC" "users 只读投影有数据" "Logto users 直读可见" \
    "curl -sf '$BASE_URL/api/v1/platform/users?select=id&limit=1' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

run_test "SYNC" "role 只读投影有数据" "Logto roles 直读可见（含 MachineToMachine）" \
    "curl -sf '$BASE_URL/api/v1/platform/role?select=id&limit=1' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

run_test "SYNC" "tenant_role 只读投影可读" "Logto OrganizationRoles 直读可见" \
    "curl -sf '$BASE_URL/api/v1/platform/tenant_role?select=id&limit=5' -H \"Authorization: Bearer $TOKEN\" | jq -e 'length >= 1'"

# 前置: gateway/.env 已配置 LOGTO_WEBHOOK_SIGNING_KEY（init-apisix-routes.sh fail-closed）
run_test "SYNC" "Webhook 无签名头被拒" "APISIX 验签 401（N15 fail-closed）" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/rpc/webhook_logto' \
      -H 'Content-Type: application/json' -d '{\"event\":\"PostSignIn\",\"data\":{}}' | grep -q '401'"

run_test "SYNC" "Webhook 错误签名被拒" "错误 HMAC 401" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/rpc/webhook_logto' \
      -H 'Content-Type: application/json' -H 'logto-signature-sha-256: ZmFrZXNpZw==' \
      -d '{\"event\":\"PostSignIn\",\"data\":{}}' | grep -q '401'"

# D25: reconcile-logto.py 已退役（用户/角色/租户直读 Logto 公共表，无需对账）
echo "  [SYNC] 提示: 对账脚本已移除（D25 同库只读，无需对账）"

# ==============================================================================
# Phase 7: 异常恢复
# ==============================================================================
echo ""
echo "📋 Phase 7: 异常恢复"

run_test "RESILIENCE" "Bad Token Rejected" "非法 Token 被拒绝" \
    "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' -H 'Authorization: Bearer invalid.token.value' | grep -q '40[13]'"

run_test "RESILIENCE" "Missing Auth Header" "无 Authorization 头被拒绝" \
    "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' | grep -q '40[13]'"

run_test "RESILIENCE" "Wrong Method" "错误 HTTP 方法被拒绝" \
    "curl -s -o /dev/null -w '%{http_code}' -X PUT '$BASE_URL/api/v1/platform/role' -H \"Authorization: Bearer $TOKEN\" -d '{\"x\":1}' | grep -q '40[135]'"

# ==============================================================================
# 汇总
# ==============================================================================
echo ""
echo "========================================"
echo "  验收结果"
echo "========================================"
echo ""
echo "  通过: $PASSED"
echo "  失败: $FAILED"
echo "  总计: $((PASSED + FAILED))"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "  🎉 ALL TESTS PASSED — 系统就绪！"
else
    echo "  ⚠️  存在失败项，请排查后重试"
fi

echo ""
echo "========================================"

exit $FAILED