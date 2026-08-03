#!/usr/bin/env bash
# =============================================================================
# 04.7 §10 JWT claims 检查脚本（V8/V9/V10/V13）
# password grant 取 access_token → 解码 payload → 输出:
#   roles 结构/顺序（H1）、isEnabled 状态（H9）、凭据字段泄漏（H3）、
#   roles=[] 行为（M6）
#
# 环境变量（必填）:
#   CASDOOR_URL, CLIENT_ID, CLIENT_SECRET, USERNAME(org/name), PASSWORD
#   被测用户建议挂 2+ 个角色（其中一个先禁用）以观察 V8/V9
# 依赖: curl, python3（Windows git-bash 自动回退 python）
# =============================================================================
: "${CASDOOR_URL:?CASDOOR_URL 必填}"
: "${CLIENT_ID:?CLIENT_ID 必填（测试应用 clientId）}"
: "${CLIENT_SECRET:?CLIENT_SECRET 必填}"
: "${USERNAME:?USERNAME 必填（格式 org/name）}"
: "${PASSWORD:?PASSWORD 必填}"
# 注意: 不能只查 command -v（Windows 的 python3 是 Store 存根，存在但执行即失败）
if python3 -c 'import sys' >/dev/null 2>&1; then PY=python3; else PY=python; fi

echo "== 请求 token (password grant) =="
RESP=$(curl -sS -X POST "$CASDOOR_URL/api/login/oauth/access_token" \
  -d "grant_type=password&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET&username=$USERNAME&password=$PASSWORD")
echo "$RESP" | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print("error:",d.get("error"),d.get("error_description") or "") if "error" in d else print("token 获取成功")'

TOKEN=$(echo "$RESP" | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

"$PY" - "$TOKEN" <<'PY'
import base64, json, sys
t = sys.argv[1].split(".")[1]
t += "=" * (-len(t) % 4)
c = json.loads(base64.urlsafe_b64decode(t))
print("\n== JWT claims ==")
print("sub:", c.get("sub"), "| aud:", c.get("aud"), "| exp-iat(秒):", (c.get("exp") or 0) - (c.get("iat") or 0))
roles = c.get("roles") or []
print("roles 数量:", len(roles))
for i, r in enumerate(roles):
    if isinstance(r, dict):
        print("  roles[%d] = {name:%s, owner:%s, displayName:%s, isEnabled:%s}" % (
            i, r.get("name"), r.get("owner"), r.get("displayName"), r.get("isEnabled")))
    else:
        print("  roles[%d] = %r (非对象——若出现说明 tokenFormat 行为异常)" % (i, r))
print("roles[0].name =", roles[0].get("name") if roles else "（空 → PostgREST 回落 anon，M6）")
leak = [k for k in ("passwordSalt", "passwordType", "preHash", "hash", "totpSecret",
                    "recoveryCodes", "ldap", "managedAccounts") if k in c]
print("凭据字段泄漏:", leak if leak else "无（已配 JWT-Custom + tokenFields）")
PY
