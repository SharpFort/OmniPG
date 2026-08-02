#!/bin/bash
# Phase 1 端到端验证（WSL 内执行）
set -u
BASE="http://localhost:8000"          # Casdoor
PGREST="http://localhost:3001"        # PostgREST
CJ=/tmp/casdoor_cookies.txt
ORG="omnipg$(date +%s)"; APP="app-phase1-e2e"; CID="phase1e2e00001"; CSEC="phase1e2esecret00000000000000000001"
UNAME="p1user$(date +%s)"; UPASS="P1test!2026"
SECRET="webhook-secret-p1"

echo "===== 0) 重启 PostgREST ====="
docker compose -f /mnt/e/Projects/OmniPG/gateway/docker-compose.yml restart postgrest >/dev/null 2>&1
sleep 6
curl -s -o /dev/null -w "postgrest health: %{http_code}\n" "$PGREST/"

echo "===== 1) Casdoor 登录 ====="
rm -f $CJ
L=$(curl -s -c $CJ -X POST "$BASE/api/login" -H "Content-Type: application/json" -d '{"type":"login","application":"app-built-in","organization":"built-in","username":"admin","password":"123"}')
echo "login: $(echo $L | head -c 80)"

echo "===== 2) 准备 org/app/角色/用户 ====="
curl -s -b $CJ -X POST "$BASE/api/add-organization" -H "Content-Type: application/json" -d "{\"owner\":\"admin\",\"name\":\"$ORG\",\"displayName\":\"OmniPG E2E\",\"passwordType\":\"bcrypt\"}" | head -c 60; echo " (add-org)"
curl -s -b $CJ -X POST "$BASE/api/add-application" -H "Content-Type: application/json" -d "{\"owner\":\"admin\",\"name\":\"$APP\",\"organization\":\"$ORG\",\"clientId\":\"$CID\",\"clientSecret\":\"$CSEC\",\"grantTypes\":[\"password\",\"authorization_code\",\"refresh_token\"],\"tokenFormat\":\"JWT\",\"redirectUris\":[\"http://localhost:5173/callback\"],\"expireInHours\":168}" | head -c 60; echo " (add-app)"
curl -s -b $CJ -X POST "$BASE/api/add-user" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\",\"email\":\"$UNAME@omnipg.dev\",\"type\":\"normal-user\"}" | head -c 60; echo " (add-user)"
curl -s -b $CJ -X POST "$BASE/api/set-password" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "userOwner=$ORG" --data-urlencode "userName=$UNAME" --data-urlencode "oldPassword=" --data-urlencode "newPassword=$UPASS" | head -c 60; echo " (set-password)"
# 分配 authenticated 角色（D10: JWT roles 恒有值；必须放在 add-user 之后，users 引用需用户存在）
curl -s -b $CJ -X POST "$BASE/api/add-role" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"authenticated\",\"displayName\":\"认证用户\",\"isEnabled\":true,\"users\":[\"$ORG/$UNAME\"]}" | head -c 60; echo " (add-role+user)"

echo "===== 3) password grant 拿真实 token ====="
T=$(curl -s -X POST "$BASE/api/login/oauth/access_token" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "grant_type=password" --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSEC" --data-urlencode "username=$UNAME" --data-urlencode "password=$UPASS")
TOKEN=$(echo "$T" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
if [ -z "$TOKEN" ]; then echo "TOKEN 获取失败: $T"; exit 1; fi
echo "token 长度: ${#TOKEN}"
echo "$TOKEN" | cut -d. -f2 | python3 -c "import sys,base64,json; p=sys.stdin.read().strip(); p+='='*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p)); print('claims: sub=%s roles=%s aud=%s' % (d.get('sub'), d.get('roles'), d.get('aud')))"

echo "===== 4) ensure_user（JIT 兜底）====="
R=$(curl -s -X POST "$PGREST/rpc/ensure_user" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}')
echo "ensure_user → $R"
SUB=$(echo "$TOKEN" | cut -d. -f2 | python3 -c "import sys,base64,json; p=sys.stdin.read().strip(); p+='='*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p))['sub'])")

echo "===== 5) DB 验证 mirror/profile ====="
export PGPASSWORD=dev_password_change_me
psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c "SELECT 'mirror: id='||id||' name='||name||' email='||email||' is_active='||is_active FROM casdoor_user_mirror WHERE id='$SUB'::uuid"
psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c "SELECT 'profile: user_id='||user_id||' tenant='||tenant_id FROM sys_user_profile WHERE user_id='$SUB'::uuid"

echo "===== 6) webhook_user_upsert（带 secret header, 无 token）====="
psql -h 127.0.0.1 -U app_owner -d app_db -q -c "INSERT INTO sys_secret (key_name,key_value) VALUES ('casdoor_webhook_secret','$SECRET') ON CONFLICT (key_name) DO UPDATE SET key_value=EXCLUDED.key_value"
PAYLOAD="{\"event\":\"update-user\",\"user\":{\"id\":\"$SUB\",\"name\":\"$UNAME\",\"displayName\":\"E2E改名\",\"email\":\"$UNAME@omnipg.dev\",\"isForbidden\":\"true\",\"isDeleted\":\"false\"}}"
R=$(curl -s -X POST "$PGREST/rpc/webhook_user_upsert" -H "X-Webhook-Secret: $SECRET" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "webhook upsert → $R"
psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c "SELECT '状态映射: displayname='||displayname||' is_active='||is_active||' (isforbidden=true 应→false)' FROM casdoor_user_mirror WHERE id='$SUB'::uuid"

echo "===== 7) webhook 密钥错误拒绝 ====="
curl -s -o /dev/null -w "wrong secret → HTTP %{http_code} (应 400/403)\n" -X POST "$PGREST/rpc/webhook_user_upsert" -H "X-Webhook-Secret: wrong" -H "Content-Type: application/json" -d "$PAYLOAD"

echo "===== 8) webhook_user_delete（软删）====="
R=$(curl -s -X POST "$PGREST/rpc/webhook_user_delete" -H "X-Webhook-Secret: $SECRET" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "webhook delete → $R"
psql -h 127.0.0.1 -U app_owner -d app_db -t -A -c "SELECT '软删: isdeleted='||isdeleted||' deleted_at='||COALESCE(deleted_at::text,'NULL')||' is_active='||is_active FROM casdoor_user_mirror WHERE id='$SUB'::uuid"

echo "===== 9) RLS 验证（token 查 /sys_user，应只见自己）====="
curl -s "$PGREST/sys_user?select=id,username,is_active" -H "Authorization: Bearer $TOKEN" | head -c 300; echo ""

echo "===== 10) 清理 ====="
curl -s -b $CJ -X POST "$BASE/api/delete-user" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"$UNAME\"}" | head -c 40; echo " (del-user)"
curl -s -b $CJ -X POST "$BASE/api/delete-role" -H "Content-Type: application/json" -d "{\"owner\":\"$ORG\",\"name\":\"authenticated\"}" | head -c 40; echo " (del-role)"
curl -s -b $CJ -X POST "$BASE/api/delete-application" -H "Content-Type: application/json" -d "{\"owner\":\"admin\",\"name\":\"$APP\",\"organization\":\"$ORG\"}" | head -c 40; echo " (del-app)"
curl -s -b $CJ -X POST "$BASE/api/delete-organization" -H "Content-Type: application/json" -d "{\"owner\":\"admin\",\"name\":\"$ORG\"}" | head -c 40; echo " (del-org)"
psql -h 127.0.0.1 -U app_owner -d app_db -q -c "DELETE FROM sys_secret WHERE key_name='casdoor_webhook_secret'"
psql -h 127.0.0.1 -U app_owner -d app_db -q -c "DELETE FROM casdoor_user_mirror WHERE id='$SUB'::uuid"
psql -h 127.0.0.1 -U app_owner -d app_db -q -c "DELETE FROM sys_user_profile WHERE user_id='$SUB'::uuid"
echo "===== E2E DONE ====="
