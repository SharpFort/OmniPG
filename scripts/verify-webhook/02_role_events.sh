#!/usr/bin/env bash
# =============================================================================
# 04.7 §10 角色事件触发脚本（V1-V7）
# 以业务 org 管理员会话驱动：add-role / update-role(挂摘用户) / 改名 / delete-role
# 以及一次"失败"update-role，供 01 接收器落盘、03 脚本解析判定。
#
# 环境变量（必填）:
#   CASDOOR_URL  如 http://localhost:8000
#   ORG          业务组织名（如 omnipg）
#   ADMIN_USER   业务 org 管理员用户名（isAdmin=true）
#   ADMIN_PASS   管理员密码
#   TEST_USER    已存在的普通用户（格式 org/name，如 omnipg/alice）
#   APP_NAME     登录所用应用名（默认 app-built-in；业务 org 登录用该 org 的应用名）
#
# 依赖: curl, jq
# 注意: 本脚本故意不 set -e（update-role 500 是待观测对象，不能中断）；
#       每步打印 HTTP 状态码与响应前 300 字符。
# =============================================================================
: "${CASDOOR_URL:?CASDOOR_URL 必填}"
: "${ORG:?ORG 必填}"
: "${ADMIN_USER:?ADMIN_USER 必填}"
: "${ADMIN_PASS:?ADMIN_PASS 必填}"
: "${TEST_USER:?TEST_USER 必填（格式 org/name）}"
APP_NAME="${APP_NAME:-app-built-in}"

COOKIE="$(mktemp)"
ROLE="verify_role_$(date +%s)"
ROLE2="${ROLE}_renamed"
BODY="$(mktemp)"
cleanup() { rm -f "$COOKIE" "$BODY"; }
trap cleanup EXIT

step() { echo; echo "===== $* ====="; }

# post <url> — 从 stdin 读 body，打印 HTTP 码 + 响应前 300 字符
post() {
  local url="$1" tmp code
  tmp="$(mktemp)"
  code=$(curl -sS -b "$COOKIE" -H 'Content-Type: application/json' -w '%{http_code}' -o "$tmp" -d @- "$url")
  echo "HTTP:$code  body: $(head -c 300 "$tmp")"
  rm -f "$tmp"
}

# 1. 登录（v3: JSON body, type=login）→ 会话 cookie
#    注: 业务 org 用户登录时 application 用该 org 的应用名（默认 app-built-in 仅对 built-in admin）
step "1. 登录 $ADMIN_USER@$ORG (app=$APP_NAME)"
curl -sS -c "$COOKIE" -H 'Content-Type: application/json' \
  -d "{\"type\":\"login\",\"application\":\"$APP_NAME\",\"organization\":\"$ORG\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  "$CASDOOR_URL/api/login" | head -c 300
echo; echo "cookie: $COOKIE"

# 2. add-role（携带 users 挂载）—— V2
step "2. add-role $ROLE (users=[$TEST_USER]) —— V2"
echo "{\"owner\":\"$ORG\",\"name\":\"$ROLE\",\"displayName\":\"$ROLE\",\"description\":\"verify\",\"isEnabled\":true,\"users\":[\"$TEST_USER\"]}" \
  | post "$CASDOOR_URL/api/add-role"

# 3. update-role：整对象提交（get-role → 改 displayName → 提交）—— V3（users 应保持完整）
step "3. update-role 整对象提交（改 displayName）—— V3"
curl -sS -b "$COOKIE" "$CASDOOR_URL/api/get-role?id=$ORG%2F$ROLE" \
  | jq -c '.data | .displayName = .displayName + "-v2"' > "$BODY"
echo "提交对象关键字段: $(jq -c '{owner,name,displayName,users}' "$BODY")"
cat "$BODY" | post "$CASDOOR_URL/api/update-role?id=$ORG%2F$ROLE"

# 4. update-role：摘掉全部用户 —— V3（users 应为空数组）
step "4. update-role 移除用户（users=[]）—— V3"
jq -c '.users = []' "$BODY" > "$BODY.new" && mv "$BODY.new" "$BODY"
cat "$BODY" | post "$CASDOOR_URL/api/update-role?id=$ORG%2F$ROLE"

# 5. 改名 —— V7（object.name=新名；requestUri 应含 ?id=ORG/旧名）
step "5. 改名 $ROLE -> $ROLE2 —— V7"
jq -c ".name = \"$ROLE2\"" "$BODY" > "$BODY.new" && mv "$BODY.new" "$BODY"
cat "$BODY" | post "$CASDOOR_URL/api/update-role?id=$ORG%2F$ROLE"

# 6. delete-role（提交整对象）—— V6
step "6. delete-role $ROLE2 —— V6"
cat "$BODY" | post "$CASDOOR_URL/api/delete-role"

# 7. 失败 update-role（不存在的角色）—— V5（预期 response 含 status:"error"，事件仍触发）
step "7. 失败 update-role（id=ORG/nonexistent）—— V5"
echo "{\"owner\":\"$ORG\",\"name\":\"nonexistent\",\"displayName\":\"x\"}" \
  | post "$CASDOOR_URL/api/update-role?id=$ORG%2Fnonexistent"

echo
echo "===== 触发完成。运行 bash 03_inspect_payloads.sh 查看 out/ 下的 payload ====="
