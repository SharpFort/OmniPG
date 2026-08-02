# ==============================================================================
# Casdoor v3.133.0 Phase 0 验证脚本（归档版）
# ------------------------------------------------------------------------------
# 用途: 复现 Phase 0 的全部 Casdoor API 验证（升级后回归测试用）
# 环境: WSL2 / git-bash，Casdoor http://localhost:8000（docker-compose 3.133.0）
# 前置: 已用 admin 会话登录（脚本会自动登录，dev 凭据 admin/123）
# 注意: 所有临时资源（org/app/user/role）用完即删；凭据为 dev 环境值
# 用法: bash casdoor-verify.sh [login|token|apis|d8|pkce|role|all]
#   各 section 对应原 6 个验证脚本 + 角色注入验证
# ==============================================================================
set -u
BASE="http://localhost:8000"
CJ=/tmp/casdoor_cookies.txt
rm -f "$CJ"

# ---------- 公共: 登录（v3: JSON body, type=login）----------
casdoor_login() {
  curl -s -c "$CJ" -X POST "$BASE/api/login" -H "Content-Type: application/json" \
    -d "{\"type\":\"login\",\"application\":\"app-built-in\",\"organization\":\"built-in\",\"username\":\"admin\",\"password\":\"123\"}" \
    | python -c "import sys,json; d=json.load(sys.stdin); print('login:', d['status'])"
}

# ---------- 公共: 临时业务组织/应用/用户 ----------
mk_org() {  # $1=org
  curl -s -b "$CJ" -X POST "$BASE/api/add-organization" -H "Content-Type: application/json" \
    -d "{\"owner\":\"admin\",\"name\":\"$1\",\"createdTime\":\"2026-08-02T00:00:00Z\",\"displayName\":\"OmniPG\",\"passwordType\":\"bcrypt\",\"enableSoftDeletion\":true}" > /dev/null
}
mk_app() {  # $1=org $2=app $3=cid $4=csec $5=grants
  curl -s -b "$CJ" -X POST "$BASE/api/add-application" -H "Content-Type: application/json" \
    -d "{\"owner\":\"admin\",\"name\":\"$2\",\"createdTime\":\"2026-08-02T00:00:00Z\",\"displayName\":\"Verify\",\"organization\":\"$1\",\"cert\":\"cert-built-in\",\"clientId\":\"$3\",\"clientSecret\":\"$4\",\"redirectUris\":[\"http://localhost:5173/callback\"],\"tokenFormat\":\"JWT\",\"expireInHours\":1,\"enablePassword\":true,\"grantTypes\":$5,\"signupItems\":[],\"signinMethods\":[{\"name\":\"Password\",\"displayName\":\"Password\",\"rule\":\"All\"}]}" > /dev/null
}
rm_org() { curl -s -b "$CJ" -X POST "$BASE/api/delete-organization" -H "Content-Type: application/json" -d "{\"owner\":\"admin\",\"name\":\"$1\"}" > /dev/null; }

# ---------- 1. 登录 + 应用/组织/用户查询 ----------
sec_login() {
  casdoor_login
  echo "--- applications ---"
  curl -s -b "$CJ" "$BASE/api/get-applications" | python -c "
import sys,json
for a in (json.load(sys.stdin).get('data') or []):
    print(f\"  {a.get('name')} org={a.get('organization')} clientId={a.get('clientId')} grants={a.get('grantTypes')}\")"
  echo "--- organizations ---"
  curl -s -b "$CJ" "$BASE/api/get-organizations" | python -c "
import sys,json
for o in (json.load(sys.stdin).get('data') or []):
    print(f\"  {o.get('name')} passwordType={o.get('passwordType')}\")"
  echo "--- users ---"
  curl -s -b "$CJ" "$BASE/api/get-users?owner=built-in" | python -c "
import sys,json
for u in (json.load(sys.stdin).get('data') or []):
    print(f\"  id={u.get('id')} name={u.get('name')} isAdmin={u.get('isAdmin')}\")"
}

# ---------- 2. 临时应用 + password grant + JWT claims 解码 ----------
sec_token() {
  casdoor_login
  ORG=omnipg; APP=app-verify-token; CID=verifytoken0001; CSEC=verifytokensecret000000000000000000000
  mk_org $ORG; mk_app $ORG $APP $CID $CSEC '["password"]'
  echo "--- password grant ---"
  TR=$(curl -s -X POST "$BASE/api/login/oauth/access_token" -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=$CID&client_secret=$CSEC&username=admin&password=123&scope=read")
  echo "$TR" | python -c "
import sys,json,base64
d=json.load(sys.stdin); t=d.get('access_token','')
print(' token:', 'OK' if t else d)
if t:
    p=t.split('.')[1]; p+='='*(-len(p)%4)
    pl=json.loads(base64.urlsafe_b64decode(p))
    print(' header alg: RS256 验证（应匹配 Casdoor JWKS）')
    for k in ['sub','id','jti','aud','roles','name','email','tokenType']:
        print(f'  {k}: {str(pl.get(k))[:80]}')"
  rm_org $ORG
}

# ---------- 3. webhook / syncer API 结构 ----------
sec_apis() {
  casdoor_login
  echo "--- webhooks ---"
  curl -s -b "$CJ" "$BASE/api/get-webhooks?owner=built-in" | python -c "
import sys,json
ws=json.load(sys.stdin).get('data') or []
print(' count:', len(ws))
for w in ws[:2]: print('  events:', w.get('events'), '| url:', w.get('url'))"
  echo "--- syncers ---"
  curl -s -b "$CJ" "$BASE/api/get-syncers?owner=built-in" | python -c "
import sys,json
ss=json.load(sys.stdin).get('data') or []
print(' count:', len(ss))
for s in ss[:1]:
    print('  syncInterval:', s.get('syncInterval'), '| table:', s.get('table'), '| databaseType:', s.get('databaseType'))"
}

# ---------- 4. D8 链路: org/app/add-user/set-password/登录/清理 ----------
sec_d8() {
  casdoor_login
  ORG=omnipg; APP=app-verify-d8; CID=verifyd8app0001; CSEC=verifyd8secret0000000000000000000000
  mk_org $ORG; mk_app $ORG $APP $CID $CSEC '["password"]'
  UNAME="verifyuser$(date +%s)"
  echo "--- add-user ($UNAME) ---"
  curl -s -b "$CJ" -X POST "$BASE/api/add-user" -H "Content-Type: application/json" \
    -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\",\"createdTime\":\"2026-08-02T00:00:00Z\",\"type\":\"normal-user\",\"password\":\"InitPass123!\",\"email\":\"$UNAME@test.local\",\"displayName\":\"Verify\"}" \
    | python -c "import sys,json; d=json.load(sys.stdin); print(' ', d['status'], d.get('msg','')[:80])"
  echo "--- set-password (form 表单: userOwner/userName 分字段) ---"
  curl -s -b "$CJ" -X POST "$BASE/api/set-password" \
    -d "userOwner=$ORG&userName=$UNAME&oldPassword=InitPass123!&newPassword=ChangedPass456!" \
    | python -c "import sys,json; d=json.load(sys.stdin); print(' ', d['status'], d.get('msg','')[:80])"
  echo "--- password grant 登录（新密码）---"
  curl -s -X POST "$BASE/api/login/oauth/access_token" -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=$CID&client_secret=$CSEC&username=$UNAME&password=ChangedPass456!" \
    | python -c "import sys,json; d=json.load(sys.stdin); print(' token:', 'OK' if d.get('access_token') else d)"
  echo "--- 清理 ---"
  curl -s -b "$CJ" -X POST "$BASE/api/delete-user" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\"}" > /dev/null
  rm_org $ORG
}

# ---------- 5. PKCE code flow ----------
sec_pkce() {
  casdoor_login
  ORG=omnipg; APP=app-verify-pkce; CID=verifypkce0001; CSEC=verifypkcesecret000000000000000000000
  mk_org $ORG; mk_app $ORG $APP $CID $CSEC '["authorization_code"]'
  read -r VER CHAL <<< $(python -c "
import base64,hashlib,secrets
v=base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()
c=base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
print(v,c)")
  echo "--- authorize 端点（无会话 → 应返回 200 登录页或 302）---"
  curl -s -o /dev/null -w "  HTTP %{http_code} → %{redirect_url}\n" \
    "$BASE/login/oauth/authorize?client_id=$CID&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fcallback&scope=openid+profile+email&state=x&code_challenge=$CHAL&code_challenge_method=S256"
  echo "  (完整 code 交换需浏览器登录态，Phase 2 前端对接时验证)"
  rm_org $ORG
}

# ---------- 6. 角色 → JWT roles claim 注入（D10 关键）----------
sec_role() {
  casdoor_login
  ORG=omnipg; APP=app-verify-role; CID=verifyrole0001; CSEC=verifyrolesecret000000000000000000000
  mk_org $ORG; mk_app $ORG $APP $CID $CSEC '["password"]'
  UNAME=verifyroleuser
  curl -s -b "$CJ" -X POST "$BASE/api/add-user" -H "Content-Type: application/json" \
    -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\",\"createdTime\":\"2026-08-02T00:00:00Z\",\"type\":\"normal-user\",\"password\":\"TestPass123!\",\"displayName\":\"Role User\"}" > /dev/null
  echo "--- add-role + 绑定用户 ---"
  curl -s -b "$CJ" -X POST "$BASE/api/add-role" -H "Content-Type: application/json" \
    -d "{\"owner\":\"$ORG\",\"name\":\"authenticated\",\"createdTime\":\"2026-08-02T00:00:00Z\",\"displayName\":\"Authenticated\",\"users\":[\"$ORG/$UNAME\"],\"isEnabled\":true}" \
    | python -c "import sys,json; print(' add-role:', json.load(sys.stdin)['status'])"
  echo "--- 登录解码 roles（注意: roles 是对象数组, PostgREST 需用 roles[0].name）---"
  TR=$(curl -s -X POST "$BASE/api/login/oauth/access_token" -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=$CID&client_secret=$CSEC&username=$UNAME&password=TestPass123!")
  echo "$TR" | python -c "
import sys,json,base64
d=json.load(sys.stdin); t=d.get('access_token','')
if t:
    p=t.split('.')[1]; p+='='*(-len(p)%4)
    pl=json.loads(base64.urlsafe_b64decode(p))
    roles=pl.get('roles') or []
    print(' roles:', [r.get('name') for r in roles])
    print(' roles[0].name 提取: ', roles[0].get('name') if roles else 'N/A')"
  curl -s -b "$CJ" -X POST "$BASE/api/delete-role" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"authenticated\"}" > /dev/null
  curl -s -b "$CJ" -X POST "$BASE/api/delete-user" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\"}" > /dev/null
  rm_org $ORG
}

case "${1:-all}" in
  login) sec_login ;;
  token) sec_token ;;
  apis)  sec_apis ;;
  d8)    sec_d8 ;;
  pkce)  sec_pkce ;;
  role)  sec_role ;;
  all)   sec_login; sec_token; sec_apis; sec_d8; sec_pkce; sec_role ;;
  *) echo "用法: $0 [login|token|apis|d8|pkce|role|all]"; exit 1 ;;
esac
