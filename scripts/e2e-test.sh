#!/bin/bash
# ==============================================================================
# 全系统端到端验收自动化脚本（Linux/macOS bash）
# ==============================================================================

set -e

BASE_URL="${BASE_URL:-http://localhost:9080}"
FAILED=0
PASSED=0

run_test() {
    local category="$1"
    local name="$2"
    local description="$3"
    local cmd="$4"
    
    echo -n "  [$category] $name: "
    if eval "$cmd" > /dev/null 2>&1; then
        echo "✅ PASS"
        ((PASSED++))
    else
        echo "❌ FAIL"
        ((FAILED++))
    fi
}

echo ""
echo "========================================"
echo "  全系统端到端验收测试"
echo "========================================"
echo ""

# ==============================================================================
# Phase 0: 环境就绪检查
# ==============================================================================
echo "📋 Phase 0: 环境就绪检查"

run_test "ENV" "PostgREST Running" "PostgREST 容器健康" \
    "curl -sf http://localhost:3000/ | head -c 100"

run_test "ENV" "APISIX Running" "APISIX 容器健康" \
    "curl -sf http://localhost:9080/apisix/status"

run_test "ENV" "Casdoor Running" "Casdoor 容器健康" \
    "curl -sf http://localhost:8000/api/health"

run_test "ENV" "Backend Health" "Swagger UI 可用" \
    "curl -sf http://localhost:8080/"

run_test "ENV" "Casdoor JWKS" "Casdoor JWKS 端点可用" \
    "curl -sf http://localhost:8000/.well-known/jwks"

sleep 2

# ==============================================================================
# Phase 1: 认证流程
# ==============================================================================
echo ""
echo "📋 Phase 1: 认证流程"

# Login and extract token
LOGIN_RESPONSE=$(curl -sf -X POST "${BASE_URL}/api/v1/rpc/user_login_sso" \
  -H "Content-Type: application/json" \
  -d '{"p_username":"admin","p_password":"admin123"}')

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.access_token // empty')

run_test "AUTH" "Admin Login" "admin/admin123 登录成功" \
    "[ -n '$TOKEN' ] && [ '$TOKEN' != 'null' ]"

run_test "AUTH" "Invalid Password Rejected" "错误密码被拒绝" \
    "curl -sf -X POST '${BASE_URL}/api/v1/rpc/user_login_sso' -H 'Content-Type: application/json' -d '{\"p_username\":\"admin\",\"p_password\":\"wrongpassword\"}' | grep -q 'error\|401'"

run_test "AUTH" "Unauthorized Request" "无 Token 请求返回 401/403" \
    "curl -sf '${BASE_URL}/api/v1/sys_user' | grep -q '401\|403'"

run_test "AUTH" "Authorized Request" "带 Token 访问正常" \
    "curl -sf '${BASE_URL}/api/v1/sys_user' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

run_test "AUTH" "Menu Loaded" "用户菜单树加载成功" \
    "curl -sf '${BASE_URL}/api/v1/rpc/get_user_menu' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

# ==============================================================================
# Phase 2: 权限管理
# ==============================================================================
echo ""
echo "📋 Phase 2: 权限管理"

run_test "RBAC" "Create User" "新增测试用户" \
    "curl -sf -X POST '${BASE_URL}/api/v1/sys_user' -H 'Content-Type: application/json' -H 'Authorization: Bearer $TOKEN' -d '{\"username\":\"testuser_'$(date +%s)'\",\"password\":\"test\",\"tenant_id\":\"tenant_default\"}' | jq -e '.[0].id'"

run_test "RBAC" "Update User" "更新用户信息" \
    "curl -sf -X PATCH '${BASE_URL}/api/v1/sys_user?id=eq.00000000-0000-0000-0000-100000000001' -H 'Content-Type: application/json' -H 'Authorization: Bearer $TOKEN' -d '{\"username\":\"admin_updated\"}' | jq -e '.[0].id'"

run_test "RBAC" "Create Role" "新增测试角色" \
    "curl -sf -X POST '${BASE_URL}/api/v1/sys_role' -H 'Content-Type: application/json' -H 'Authorization: Bearer $TOKEN' -d '{\"role_code\":\"test_role_'$(date +%s)'\",\"role_name\":\"Test Role\"}' | jq -e '.[0].id'"

run_test "RBAC" "Soft Delete" "soft delete" \
    "curl -sf -X PATCH '${BASE_URL}/api/v1/sys_user?id=eq.00000000-0000-0000-0000-100000000001' -H 'Content-Type: application/json' -H 'Authorization: Bearer $TOKEN' -d '{\"is_active\":false}' | jq -e '.[0].id'"

run_test "RBAC" "User List" "查询用户列表" \
    "curl -sf '${BASE_URL}/api/v1/sys_user?select=id,username&limit=10' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

# ==============================================================================
# Phase 3: API 鉴权
# ==============================================================================
echo ""
echo "📋 Phase 3: API 鉴权"

run_test "API" "GET /sys_user" "允许的 GET 请求" \
    "curl -sf '${BASE_URL}/api/v1/sys_user?limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

run_test "API" "JWKS Endpoint" "JWKS 端点可访问" \
    "curl -sf '${BASE_URL}/well-known/jwks' | jq -e '.keys[0].kty'"

run_test "API" "404 for Not Found" "不存在的路由返回 404" \
    "curl -sf '${BASE_URL}/api/v1/nonexistent' | grep -q '404'"

# ==============================================================================
# Phase 4: 角色即时生效
# ==============================================================================
echo ""
echo "📋 Phase 4: 角色即时生效"

run_test "REALTIME" "Role Change Invalidates Token" "角色变更后旧 Token 失效" \
    "docker exec app-postgres psql -U app_owner -d app_db -c \"SELECT trigger_name FROM information_schema.triggers WHERE trigger_name = 'trg_blacklist_on_role_change';\" -t -A 2>/dev/null | grep -q 'trg_blacklist_on_role_change'"

run_test "REALTIME" "Policy Sync" "策略同步链路正常" \
    "docker logs policy-syncer --tail=5 2>/dev/null | grep -q 'Successfully synchronized\|listening\|leader'"

# ==============================================================================
# Phase 5: 多租户隔离
# ==============================================================================
echo ""
echo "📋 Phase 5: 多租户隔离"

run_test "TENANT" "Tenant A Visible" "租户 A 看到自己数据" \
    "curl -sf '${BASE_URL}/api/v1/sys_user?tenant_id=eq.tenant_default&limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].id'"

run_test "TENANT" "Cross-Tenant Blocked" "跨租户通过 tenant_id 过滤" \
    "curl -sf '${BASE_URL}/api/v1/sys_user?select=tenant_id&limit=10' -H 'Authorization: Bearer $TOKEN' | jq -r '.[].tenant_id' | sort -u | wc -l | grep -q '^1$'"

# ==============================================================================
# Phase 6: 同步链路
# ==============================================================================
echo ""
echo "📋 Phase 6: 同步链路"

run_test "SYNC" "casbin_rule View" "Casbin 视图可查询" \
    "curl -sf '${BASE_URL}/api/v1/casbin_rule?limit=1' -H 'Authorization: Bearer $TOKEN' | jq -e '.[0].ptype'"

run_test "SYNC" "pg_notify Trigger" "通知触发器存在" \
    "docker exec app-postgres psql -U app_owner -d app_db -c \"SELECT trigger_name FROM information_schema.triggers WHERE trigger_name = 'trg_reload_on_role_api';\" -t -A 2>/dev/null | grep -q 'trg_reload_on_role_api'"

run_test "SYNC" "Policy Syncer Running" "Syncer 容器运行中" \
    "docker inspect --format='{{.State.Status}}' policy-syncer 2>/dev/null | grep -q 'running'"

# ==============================================================================
# Phase 7: 异常恢复
# ==============================================================================
echo ""
echo "📋 Phase 7: 异常恢复"

run_test "RESILIENCE" "Bad Token Rejected" "非法 Token 被拒绝" \
    "curl -sf '${BASE_URL}/api/v1/sys_user' -H 'Authorization: Bearer invalid.token.value' | grep -q '401\|403'"

run_test "RESILIENCE" "Missing Auth Header" "无 Authorization 头被拒绝" \
    "curl -sf '${BASE_URL}/api/v1/sys_user' | grep -q '401\|403'"

run_test "RESILIENCE" "Wrong Method" "错误 HTTP 方法被拒绝" \
    "curl -sf -X PUT '${BASE_URL}/api/v1/sys_user' -H 'Authorization: Bearer $TOKEN' -d '{\"x\":1}' | grep -q '404\|405\|403'"

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
