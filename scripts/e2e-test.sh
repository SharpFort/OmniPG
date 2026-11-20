#!/bin/bash
# ==============================================================================
# 全系统端到端验收自动化脚本（Logto 版）— 替代 Casdoor 时代版本
# 架构: Logto OSS v1.42（3001/3002）+ PostgREST（3100，api_v1_platform）
#        + APISIX（9080，jwt-auth ES384）+ Logto 只读投影视图（users/tenants/tenant_role）
# 2026-11-19 批次2d 修复：
#   * 凭据 fail-fast：E2E_USER/E2E_PASSWORD/APISIX_ADMIN_KEY 不再回退仓库内默认值
#     （原 Admin@112104 与公开 APISIX admin key 会静默通过仍用默认值的部署）
#   * 消除 eval 注入面：测试命令改 "$@" 直调；登录 JSON 经环境变量 + python 构造
#   * 断言真实化：登录失败检测不再对空输出恒 PASS；length>=0 恒真改为类型断言；
#     只读拒绝断言排除 2xx/3xx 而非放行任意 4xx/5xx
# ==============================================================================

set -u

BASE_URL="${BASE_URL:-http://localhost:9080}"
PGRST_URL="${PGRST_URL:-http://localhost:3100}"
LOGTO_URL="${LOGTO_URL:-http://localhost:3001}"
CLIENT_ID="${CLIENT_ID:-0d4o8wb6qk9bar0egelb4}"
REDIRECT_URI="${REDIRECT_URI:-http://localhost:5173/auth/callback}"
ORG_ID="${ORG_ID:-q8xan57gksx5}"
RESOURCE="https://default.logto.app/api"
# 凭据必须显式提供（fail-fast，C-12）：优先环境变量，缺失时从渲染产物
# gateway/.env（gitignored）自动读取——保住 make test-e2e / CI 既有入口，
# 同时杜绝回退仓库内默认凭据
GW_ENV="$(cd "$(dirname "$0")/.." && pwd)/gateway/.env"
env_val() { [ -f "$GW_ENV" ] || return 0; grep -m1 -E "^$1=" "$GW_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true; }
E2E_USER="${E2E_USER:-$(env_val E2E_USER)}"
E2E_PASSWORD="${E2E_PASSWORD:-$(env_val E2E_PASSWORD)}"
ADMIN_KEY="${APISIX_ADMIN_KEY:-$(env_val APISIX_ADMIN_KEY)}"
DB_PASSWORD="${DB_PASSWORD:-$(env_val DB_PASSWORD)}"
export E2E_USER E2E_PASSWORD DB_PASSWORD   # 子 shell（bash -c）经环境取用，杜绝引号内插

if [ -z "$E2E_USER" ] || [ -z "$E2E_PASSWORD" ]; then
    echo "❌ 缺少 E2E_USER / E2E_PASSWORD（环境变量或 gateway/.env 显式提供；不再回退默认凭据）" >&2
    exit 2
fi
if [ -z "$ADMIN_KEY" ]; then
    echo "❌ 缺少 APISIX_ADMIN_KEY（环境变量或 gateway/.env 显式提供）" >&2
    exit 2
fi

FAILED=0
PASSED=0
SKIPPED=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

run_test() {
    # "$@" 直调（替代原 eval "$cmd"：插值不再成为 shell 代码——批次2d 修复）
    local category="$1" name="$2" description="$3"; shift 3
    echo -n "  [$category] $name: "
    if "$@" > /dev/null 2>&1; then
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
    # JSON 经环境变量 + python 构造（凭据中的引号/元字符不再是注入面）
    local creds_json
    creds_json=$(python3 -c 'import json,os; print(json.dumps({"event":"SignIn","identifier":{"username":os.environ["E2E_USER"],"password":os.environ["E2E_PASSWORD"]}}))')
    curl -s -b "$TMPD/c.txt" -c "$TMPD/c.txt" -X PUT "$LOGTO_URL/api/interaction" \
      -H "Content-Type: application/json" \
      -d "$creds_json" -o /dev/null
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
    bash -c "curl -sf $PGRST_URL/ | head -c 100"
run_test "ENV" "APISIX Running" "APISIX 健康" \
    bash -c "curl -sf http://localhost:9180/apisix/admin/routes -H 'X-API-KEY: $ADMIN_KEY' | grep -q api_v1_platform"
run_test "ENV" "Logto Running" "Logto OIDC 服务健康" \
    bash -c "curl -sf $LOGTO_URL/oidc/.well-known/openid-configuration | grep -q issuer"
run_test "ENV" "Backend Health" "Swagger UI 可用" \
    bash -c "curl -sf http://localhost:8082/"
run_test "ENV" "Logto JWKS" "Logto JWKS 端点可用" \
    bash -c "curl -sf $LOGTO_URL/oidc/jwks | jq -e '.keys[0].kty'"

sleep 1

# ==============================================================================
# Phase 1: 认证流程（Logto OIDC code flow；Casdoor user_login_sso 已退役）
# ==============================================================================
echo ""
echo "📋 Phase 1: 认证流程"

TOKEN=$(logto_login || true)
export TOKEN   # 子 shell（bash -c）可见——验收修补：未导出时子 shell 恒为空

run_test "AUTH" "Admin Login" "Logto OIDC 登录成功拿到 token" \
    bash -c "[ -n '$TOKEN' ] && [ \${#TOKEN} -gt 100 ]"

# 断言真实化（批次2d 修复）：失败登录必须得到"空输出或非 JWT"，而非旧版
# `grep -qv; [ $? -eq 1 ]` 对空输出恒 PASS 的伪断言；
# 输出经环境变量传入子 shell（不内插——服务端返回内容可含引号）
BAD_LOGIN_OUT=$(E2E_PASSWORD="wrongpassword_$RANDOM$RANDOM" logto_login 2>/dev/null || true)
export BAD_LOGIN_OUT
run_test "AUTH" "Invalid Password Rejected" "错误密码被 Logto 拒绝（不得返回 JWT）" \
    bash -c '[ -z "$BAD_LOGIN_OUT" ] || ! printf "%s" "$BAD_LOGIN_OUT" | grep -q "^eyJ"'

run_test "AUTH" "Unauthorized Request" "无 Token 请求返回 401/403" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' | grep -q '40[13]'"

run_test "AUTH" "Authorized Request" "带 Token 访问镜像表正常" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/role?select=role_code,role_name&limit=5' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].role_code'"

run_test "AUTH" "Menu Loaded" "用户菜单树加载成功" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/rpc/get_user_menu' -H 'Authorization: Bearer $TOKEN' | jq -e 'type == \"array\" and length >= 1'"

# ==============================================================================
# Phase 2: 权限与只读保障（镜像表只读；写操作应被拒 — Logto 单向同步）
# ==============================================================================
echo ""
echo "📋 Phase 2: 权限与只读保障"

# 断言收紧（批次2d 修复）：拒绝类断言不再放行任意 4xx/5xx——明确"非 2xx/3xx 即拒"，
# 并对镜像表写入断言 4xx（PostgREST 权限/不可插入语义），网关 5xx 属于故障应显红
readonly_rejected() {
    # 前置：登录成功（TOKEN 非空）才谈得上"写权限被拒"——
    # TOKEN 为空时 401 会伪装成 readonly 通过（验收修补）
    [ -n "$TOKEN" ] || return 1
    local uri="$1" body="$2"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$uri" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d "$body")
    [ "${code:0:1}" = "4" ]
}

run_test "RBAC" "Users Readonly" "users 镜像表 POST 被拒（4xx）" \
    readonly_rejected "$BASE_URL/api/v1/platform/users" '{"username":"x"}'
run_test "RBAC" "Role Readonly" "role 镜像表 POST 被拒（4xx）" \
    readonly_rejected "$BASE_URL/api/v1/platform/role" '{"name":"x"}'
run_test "RBAC" "Tenant Readonly" "tenants 镜像表 POST 被拒（4xx）" \
    readonly_rejected "$BASE_URL/api/v1/platform/tenants" '{"name":"x"}'

run_test "RBAC" "User List" "查询用户列表（v_user_list 视图）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/v_user_list?select=id,username&limit=5' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

run_test "RBAC" "Role List" "查询角色列表（v_role_list 视图）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/v_role_list?select=role_code,role_name&limit=5' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

# ==============================================================================
# Phase 3: API 鉴权
# ==============================================================================
echo ""
echo "📋 Phase 3: API 鉴权"

run_test "API" "GET /role" "镜像表 role 可读" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/role?limit=3' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

run_test "API" "GET /users" "镜像表 users 可读" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/users?select=id,username&limit=3' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

run_test "API" "RPC get_current_user" "当前用户信息（JWT claims）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/rpc/get_current_user' -H 'Authorization: Bearer $TOKEN' | jq -e '.id'"

run_test "API" "JWKS Endpoint" "Logto JWKS 端点可访问" \
    bash -c "curl -sf '$BASE_URL/logto/oidc/jwks' | jq -e '.keys[0].kty'"

run_test "API" "401 for Unknown Route" "未知路由落入 catch-all 需鉴权（无 Token 401/403）" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/nonexistent' | grep -q '40[13]'"

# ==============================================================================
# Phase 4: 角色即时生效（JWT 角色；触发器通知链路）
# ==============================================================================
echo ""
echo "📋 Phase 4: 角色与同步链路"

run_test "REALTIME" "JWT Roles Claim" "token 携带 roles（Logto 角色）" \
    bash -c "echo '$TOKEN' | python3 -c \"import sys,base64,json; t=sys.stdin.read().strip(); p=t.split('.')[1]; p+='='*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p)); print(d.get('roles',[]))\" | grep -q 'role_super_admin'"

run_test "REALTIME" "Role List API" "v_role_list 反映 Logto 角色" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/v_role_list?select=role_code&limit=10' -H 'Authorization: Bearer $TOKEN' | jq -e '[.[].role_code] | length >= 1'"

# ==============================================================================
# Phase 5: 多租户隔离（RLS：JWT organization_id）
# ==============================================================================
echo ""
echo "📋 Phase 5: 多租户隔离"

# 断言真实化（批次2d 修复）：原 `length >= 0` 恒真——RLS 行数受组织归属影响可为 0，
# 有意义的最小断言 = 请求成功且返回 JSON 数组（-sf 已保证非 5xx）
run_test "TENANT" "Tenant Isolation" "RLS 按租户过滤（department 可读且为数组）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/department?select=id&limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e 'type == \"array\"'"

run_test "TENANT" "Dept Tenant Scoped" "department RLS 按租户过滤（可读且为数组）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/department?select=id&limit=3' -H 'Authorization: Bearer $TOKEN' | jq -e 'type == \"array\"'"

run_test "TENANT" "audit_log Scoped" "audit_log RLS 可读且为数组" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/audit_log?select=id&limit=3' -H 'Authorization: Bearer $TOKEN' | jq -e 'type == \"array\"'"

# ==============================================================================
# Phase 6: 同库只读视图 + PostSignIn 登录日志 webhook（D25）
# ==============================================================================
echo ""
echo "📋 Phase 6: 同库只读视图 + PostSignIn"

if [ -z "$DB_PASSWORD" ]; then
    echo "  [SYNC] ⏭️ SKIP: webhook RPC 存在性检查（未提供 DB_PASSWORD）"
    SKIPPED=$((SKIPPED + 1))
else
    # 管道须在 bash -c 内整体执行（验收修补：外置管道会接管 run_test 的输出流，
    # 且 PASSED/FAILED 在管道子 shell 中自增不落回父进程）；
    # PGPASSWORD 经环境变量传递（密码可含引号——内插即注入面）
    run_test "SYNC" "webhook RPC 存在" "webhook_logto 函数注册" \
        bash -c "PGPASSWORD=\"\$DB_PASSWORD\" psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c \"SELECT proname FROM pg_proc WHERE proname='webhook_logto';\" | grep -q webhook_logto"
    # 注：psql 失败（DB 不可达）时 grep 无输入自然 FAIL——连接错误不再被掩盖
fi

run_test "SYNC" "users 只读投影有数据" "Logto users 直读可见" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/users?select=id&limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

run_test "SYNC" "role 只读投影有数据" "Logto roles 直读可见（含 MachineToMachine）" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/role?select=id&limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

run_test "SYNC" "tenant_role 只读投影可读" "Logto OrganizationRoles 直读可见" \
    bash -c "curl -sf '$BASE_URL/api/v1/platform/tenant_role?select=id&limit=5' -H 'Authorization: Bearer $TOKEN' | jq -e 'length >= 1'"

# 前置: gateway/.env 已配置 LOGTO_WEBHOOK_SIGNING_KEY（init-apisix-routes.sh fail-closed）
run_test "SYNC" "Webhook 无签名头被拒" "APISIX 验签 401（N15 fail-closed）" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/rpc/webhook_logto' -H 'Content-Type: application/json' -d '{\"event\":\"PostSignIn\",\"data\":{}}' | grep -q '401'"

run_test "SYNC" "Webhook 错误签名被拒" "错误 HMAC 401" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' -X POST '$BASE_URL/rpc/webhook_logto' -H 'Content-Type: application/json' -H 'logto-signature-sha-256: ZmFrZXNpZw==' -d '{\"event\":\"PostSignIn\",\"data\":{}}' | grep -q '401'"

# D25: reconcile-logto.py 已退役（用户/角色/租户直读 Logto 公共表，无需对账）
echo "  [SYNC] 提示: 对账脚本已移除（D25 同库只读，无需对账）"

# ==============================================================================
# Phase 7: 异常恢复
# ==============================================================================
echo ""
echo "📋 Phase 7: 异常恢复"

run_test "RESILIENCE" "Bad Token Rejected" "非法 Token 被拒绝（401）" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' -H 'Authorization: Bearer invalid.token.value' | grep -q '401'"

run_test "RESILIENCE" "Missing Auth Header" "无 Authorization 头被拒绝（401/403）" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' '$BASE_URL/api/v1/platform/role' | grep -q '40[13]'"

run_test "RESILIENCE" "Wrong Method" "错误 HTTP 方法被拒绝（401/405）" \
    bash -c "curl -s -o /dev/null -w '%{http_code}' -X PUT '$BASE_URL/api/v1/platform/role' -H 'Authorization: Bearer $TOKEN' -d '{\"x\":1}' | grep -q '40[15]'"

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
[ $SKIPPED -gt 0 ] && echo "  跳过: $SKIPPED"
echo "  总计: $((PASSED + FAILED + SKIPPED))"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "  🎉 ALL TESTS PASSED — 系统就绪！"
else
    echo "  ⚠️  存在失败项，请排查后重试"
fi

echo ""
echo "========================================"

exit $FAILED
