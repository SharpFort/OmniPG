#!/bin/bash
# APISIX route init — Logto 版（2026-08-19 起为唯一部署链路由脚本；
#   Makefile dev / deploy-all.sh / deploy-gateway.yml 均已接入；Casdoor 时代 setup_apisix.sh 已删除）
# 变更: jwt-auth HS256→RS256（Logto JWKS）；移除 Casdoor 路由；
#       新增 /logto/* 同源代理；新增 /rpc/webhook_logto（webhook 接收入口）
#       新增 POST /rpc/ensure_user（JIT 建档，authenticated 调）
set -euo pipefail

# 2026-11-22 安全收口（citywalk 扫描 P1-1）：公知默认 key 兜底删除——
# edd1c9f034335f136f87ad84b625c8f1 为 APISIX 官方示例 key（全网公开），
# 缺 env 静默回落 = 路由面裸奔。缺失即拒绝执行（fail-closed，对齐 N15 webhook
# key 同款姿势）；与 compose ${APISIX_ADMIN_KEY:?} 构成双保险
ADMIN_KEY="${APISIX_ADMIN_KEY:-}"
if [ -z "$ADMIN_KEY" ]; then
  echo "✗✗ 缺少 APISIX_ADMIN_KEY（gateway/.env）——公知默认 key 兜底已移除：拒绝执行" >&2
  exit 1
fi
AUTH="X-API-KEY: ${ADMIN_KEY}"

# ---------------------------------------------------------------------------
# [0] 预先清理 Casdoor 时代旧路由（幂等：DELETE 不存在路由 204）
#     含 api_v1_sys（027 schema 重命名后的残留，指向已删 schema）
# ---------------------------------------------------------------------------
echo "[0] Cleanup Casdoor routes..."
for rid in jwks user_login_sso refresh_token_rtr casdoor_proxy api_v1_sys api_v1_sales api_v1_inventory; do
  curl -s -X DELETE "http://localhost:9180/apisix/admin/routes/${rid}" -H "$AUTH" || true
done
echo "  OK"

# ---------------------------------------------------------------------------
# [1] 等待 APISIX 就绪
# ---------------------------------------------------------------------------
echo "[1] Wait APISIX..."
for i in $(seq 1 15); do
  curl -sf http://localhost:7085/status 2>/dev/null | grep -q '"status":"ok"' && break
  sleep 1
done
echo "  OK"

# ---------------------------------------------------------------------------
# [2] 获取 Logto JWKS（RS256 公钥）并注入 jwt-auth 元数据
#     Logto OIDC discovery: /.well-known/openid-configuration → jwks_uri
# ---------------------------------------------------------------------------
echo "[2] Fetch Logto JWKS..."
LOGTO_OIDC="http://localhost:3001/oidc/.well-known/openid-configuration"
LOGTO_DISCOVERY=$(curl -sf "$LOGTO_OIDC")
if [ -z "$LOGTO_DISCOVERY" ]; then
  echo "  ERROR: Cannot fetch Logto discovery; is Logto running at localhost:3001?"
  exit 2
fi
JWKS_URI=$(echo "$LOGTO_DISCOVERY" | ${PYTHON:-python3} -c "import sys,json; print(json.load(sys.stdin)['jwks_uri'])" 2>/dev/null || echo "http://localhost:3001/oidc/jwks")
LOGTO_ISSUER=$(echo "$LOGTO_DISCOVERY" | ${PYTHON:-python3} -c "import sys,json; print(json.load(sys.stdin)['issuer'])" 2>/dev/null)
echo "  JWKS URI: $JWKS_URI / issuer: $LOGTO_ISSUER"
JWKS_JSON=$(curl -sf "$JWKS_URI")
if [ -z "$JWKS_JSON" ]; then
  echo "  ERROR: Cannot fetch Logto JWKS; is Logto running at localhost:3001?"
  exit 2
fi
echo "  JWKS fetched OK"

# jwt-auth consumer 引导（2026-11-22 修复，P1 批验证填坑）：
#   APISIX 3.x jwt-auth 的验签/查表都走 consumer 凭据——plugin_metadata/jwt-auth
#   在 3.17 源码中无消费方（原 [2] 步骤为无效写操作），真实生效的 consumer 此前
#   仅存于 etcd（Dashboard 手工创建），清卷/冷启动即丢失 → 认证路由全量 401
#   （"Invalid user key in JWT token"）。此处代码化重建：
#   * key = iss claim（同环境全部 Logto token 恒定 → 单 consumer 覆盖全部用户；
#     key_claim_name 已同步改 iss，见 [4] 路由段）
#   * algorithm/public_key = 从 JWKS EC P-384 公钥现场派生 PEM（无第三方依赖）
#   * 幂等 PUT：JWKS 轮换后重跑本脚本即更新
CONSUMER_JSON=$(LOGTO_ISSUER="$LOGTO_ISSUER" JWKS_JSON="$JWKS_JSON" ${PYTHON:-python3} -c '
import json, os, base64
# JWKS EC(P-384) JWK → SubjectPublicKeyInfo PEM（纯标准库手工 DER，无第三方依赖；
# 签名格式差异说明：JOSE/ES384 签名为 P1363 裸 R||S，lua-resty-jwt 内部处理）
def b64u(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
k = next(x for x in json.loads(os.environ["JWKS_JSON"])["keys"] if x.get("use","sig") == "sig" and x["kty"] == "EC")
def der_len(n):
    if n < 128: return bytes([n])
    if n < 256: return bytes([0x81, n])
    return bytes([0x82, n >> 8, n & 0xFF])
def tlv(tag, value): return bytes([tag]) + der_len(len(value)) + value
def enc_base128(n):
    g = [n & 0x7F]; n >>= 7
    while n: g.append((n & 0x7F) | 0x80); n >>= 7
    return bytes(reversed(g))
def oid(s):
    p = [int(x) for x in s.split(".")]
    return bytes([p[0]*40+p[1]]) + b"".join(enc_base128(n) for n in p[2:])
point = b"\x04" + b64u(k["x"]).rjust(48, b"\x00") + b64u(k["y"]).rjust(48, b"\x00")
spki = tlv(0x30, tlv(0x30, tlv(0x06, oid("1.2.840.10045.2.1")) + tlv(0x06, oid("1.3.132.0.34"))) + tlv(0x03, b"\x00" + point))
b64 = base64.b64encode(spki).decode()
pem = "-----BEGIN PUBLIC KEY-----\n" + "\n".join(b64[i:i+64] for i in range(0,len(b64),64)) + "\n-----END PUBLIC KEY-----\n"
print(json.dumps({"username":"logto-users","plugins":{"jwt-auth":{"key":os.environ["LOGTO_ISSUER"],"algorithm":k.get("alg","ES384"),"public_key":pem}}}))
')
if [ -n "$CONSUMER_JSON" ]; then
  RESP=$(curl -sS -w '\n%{http_code}' -X PUT http://localhost:9180/apisix/admin/consumers \
    -H "$AUTH" -H 'Content-Type: application/json' -d "$CONSUMER_JSON" 2>&1)
  CODE="${RESP##*$'\n'}"
  if [[ "$CODE" =~ ^2[0-9]{2}$ ]]; then
    echo "  jwt-auth consumer logto-users OK（key=iss, ES384 公钥自 JWKS 派生）"
  else
    echo "  ✗ consumer 引导失败 HTTP $CODE: ${RESP%$'\n'*}" >&2
    exit 1
  fi
else
  echo "  ✗ JWKS 解析失败（非 EC 签名密钥？）——consumer 引导 fail-closed" >&2
  exit 1
fi

# jwt-auth 插件元数据（历史兼容保留；3.17 的 jwt-auth 不读取 metadata，真实
# 验签走上方 consumer 凭据——留此 PUT 仅作环境快照参考）
curl -s -X PUT http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"algorithm\":\"RS256\",\"key\":$(echo "$JWKS_JSON" | ${PYTHON:-python3} -c 'import sys,json; print(json.dumps(json.dumps(json.load(sys.stdin))))')}" >/dev/null
echo "  plugin_metadata written（兼容留档）"

# ---------------------------------------------------------------------------
# [3] Global CORS + 基础限流
# ---------------------------------------------------------------------------
echo "[3] Global CORS + rate limit..."
# 限流（2026-11-22 安全收口，citywalk 扫描 P1-3）：
#   此前 global_rules 仅 cors，7 条路由零限流——认证后的爆破/枚举（证件号探测、
#   通知轰炸）在网关层无闸门。分层设计：
#   * 全局兜底：limit-req 100 r/s/IP + burst 200（漏桶平滑；单 IP 超限 503）
#   * 认证 API（rpc_all / api_v1_platform）：per-route 50 r/s + burst 100
#   * JIT 建档（ensure_user，登录期突发）：20 r/s + burst 50
#   * webhook（Logto 容器单源 IP，登录风暴批量事件）：单独放宽 200 r/s
#   * JWKS / logto_proxy：仅受全局兜底约束（预期公开，单独放宽）
#   key=remote_addr：宿主 9080 为 0.0.0.0 DNAT 直通，客户端真实源 IP 保留；
#   若前置 LB/反代需改用 X-Forwarded-For 派生 key 并信任 proxy 端
curl -s -X PUT http://localhost:9180/apisix/admin/global_rules/1 \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"plugins":{"cors":{"allow_origins":"*","allow_methods":"GET,POST,PUT,PATCH,DELETE,OPTIONS","allow_headers":"Authorization,Content-Type,X-Requested-With,logto-signature-sha-256","expose_headers":"X-Total-Count,Content-Range","max_age":3600,"allow_credentials":false},"limit-req":{"rate":100,"burst":200,"key":"remote_addr","rejected_code":503}}}'
echo "  OK（2026-11-19 批次2d 修复：allow_credentials=false——前端为 Bearer 认证不依赖 Cookie，" \
     "原 *+credentials 组合违反 CORS 规范、带凭请求会被浏览器整体拒绝；" \
     "2026-11-22 P1-3：global_rules 补 limit-req 全局兜底）"

# ---------------------------------------------------------------------------
# [4] Routes
# ---------------------------------------------------------------------------
echo "[4] Routes..."
put() {
    # 发布结果校验（验收修补）：原 curl -s 无 -f，4xx/5xx 也返回 0 且响应体被丢弃——
    # 错误 admin key / 非法路由 payload 会静默"成功"
    local resp code body
    resp=$(curl -sS -w '\n%{http_code}' -X PUT "http://localhost:9180/apisix/admin/routes/$1" -H "$AUTH" -H 'Content-Type: application/json' -d "$2" 2>&1)
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    if [[ ! "$code" =~ ^2[0-9]{2}$ ]]; then
        echo "  ✗ 路由发布失败 [$1] HTTP $code: $body" >&2
        exit 1
    fi
}

# 4.1 Logto JWKS 代理（前端 SDK / OIDC 客户端拉取公钥）
put logto_jwks '{"uri":"/.well-known/jwks","upstream":{"type":"roundrobin","nodes":{"app-logto:3001":1}},"priority":100}'

# 4.2 Logto 同源代理 /logto/*（前端 SDK endpoint，CORS 规避；若配置 Logto CORS 则可去掉此路由）
put logto_proxy '{"uri":"/logto/*","upstream":{"type":"roundrobin","nodes":{"app-logto:3001":1}},"priority":60,"plugins":{"proxy-rewrite":{"regex_uri":["^/logto/(.*)","/$1"]}}}'

# 4.3 Webhook 接收入口 — /rpc/webhook_logto（POST，web_anon 可调，无 jwt-auth）
#     验签由 APISIX serverless-pre-function 完成（HMAC-SHA256(rawBody) vs logto-signature-sha-256）
#     注意：不可叠加 request-validation（其 JSON 重排会破坏 rawBody 签名）
#     注意：大 body（>client_body_buffer_size）会落临时文件，须 get_body_file() 回退读取
WEBHOOK_SIGNING_KEY="${LOGTO_WEBHOOK_SIGNING_KEY:-}"
if [ -z "$WEBHOOK_SIGNING_KEY" ]; then
  echo "  ✗✗ 缺少 LOGTO_WEBHOOK_SIGNING_KEY（gateway/.env）——webhook 验签 fail-closed（N15）：拒绝部署" >&2
  exit 1
fi
export WEBHOOK_SIGNING_KEY
# 用 python 生成路由 JSON（避免 bash 内嵌 Lua 转义地狱）
cat > .webhook_verify.lua <<'LUA'
return function(conf, ctx)
  local resty_hmac = require('resty.openssl.hmac')
  local resty_str = require('resty.string')
  -- APISIX serverless-pre-function: 函数 conf 参数 = 整个插件配置对象，
  -- signing_key 放在 schema 允许的 conf 字段内（顶层未知字段会被 APISIX 丢弃）
  local key = (conf.conf and conf.conf.signing_key) or conf.signing_key
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  if not body then
    local file = ngx.req.get_body_file()
    if file then
      local f = assert(io.open(file, 'rb'))
      body = f:read('*a')
      f:close()
    end
  end
  body = body or ''
  local sig = ngx.var.http_logto_signature_sha_256 or ''
  if sig == '' then return ngx.exit(401) end
  local hmac = resty_hmac.new(key, 'sha256')
  hmac:update(body)
  local expected = resty_str.to_hex(hmac:final())
  -- 常量时间逐字节对比（防范时序分析反推哈希攻击）
  local match = (#expected == #sig)
  local len = math.min(#expected, #sig)
  for i = 1, len do
    if expected:byte(i) ~= sig:byte(i) then
      match = false
    end
  end
  if not match then
    -- 安全日志脱敏：严禁在服务端日志中明文打印期望生成的哈希签名
    ngx.log(ngx.WARN, 'webhook signature verification failed: invalid signature')
    return ngx.exit(401)
  end
end
LUA
WEBHOOK_LUA="$(cat .webhook_verify.lua)"
rm -f .webhook_verify.lua
export WEBHOOK_LUA
WEBHOOK_JSON="$(${PYTHON:-python3} -c '
import json, os
lua_fn = os.environ["WEBHOOK_LUA"]
route = {
    "uri": "/rpc/webhook_logto",
    "upstream": {"type": "roundrobin", "nodes": {"app-postgrest:3000": 1}},
    "priority": 95,
    "methods": ["POST"],
    "plugins": {
        "serverless-pre-function": {
            "phase": "access",
            "functions": [lua_fn],
            "conf": {"signing_key": os.environ["WEBHOOK_SIGNING_KEY"]},
        },
        # P1-3：Logto 容器单源 IP 批量事件（登录风暴），单独放宽至 200 r/s
        "limit-req": {"rate": 200, "burst": 500, "key": "remote_addr", "rejected_code": 503},
    },
}
print(json.dumps(route))
')"
put webhook_logto "$WEBHOOK_JSON"

# 4.4 JIT 建档 — /rpc/ensure_user（POST，需要 JWT auth；P1-3: 登录期突发 20 r/s）
put ensure_user '{"uri":"/rpc/ensure_user","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":80,"methods":["POST"],"plugins":{"jwt-auth":{"key_claim_name":"iss"},"limit-req":{"rate":20,"burst":50,"key":"remote_addr","rejected_code":503}}}'

# 4.5 API v1 路由（业务 API，需 jwt-auth + proxy-rewrite 去掉前缀映射 schema；P1-3: 50 r/s）
put api_v1_platform '{"uri":"/api/v1/platform/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":50,"plugins":{"proxy-rewrite":{"regex_uri":["^/api/v1/platform/(.*)","/$1"]},"jwt-auth":{"key_claim_name":"iss"},"limit-req":{"rate":50,"burst":100,"key":"remote_addr","rejected_code":503}}}'
# （2026-08-15: api_v1_sales / api_v1_inventory 测试模块退役，路由移除；后续模块按需重建）

# 4.6 RPC 路由（所有带 jwt-auth 的 RPC，匹配 /rpc/* 但排除 webhook_logto — 确保 webhook_logto 优先级更高；P1-3: 50 r/s）
put rpc_all '{"uri":"/rpc/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":40,"plugins":{"jwt-auth":{"key_claim_name":"iss"},"limit-req":{"rate":50,"burst":100,"key":"remote_addr","rejected_code":503}}}'

# 4.7 Catch-all（AuthN 准入）
put catch_all '{"uri":"/*","upstream":{"type":"roundrobin","nodes":{"app-postgrest:3000":1}},"priority":10,"plugins":{"jwt-auth":{"key_claim_name":"iss"}}}'

# ---------------------------------------------------------------------------
# [5] 汇总
# ---------------------------------------------------------------------------
echo
COUNT=$(curl -s http://localhost:9180/apisix/admin/routes -H "$AUTH" | ${PYTHON:-python3} -c 'import sys,json; print(len(json.load(sys.stdin)["list"]))')
echo "  ${COUNT} routes configured"
echo "  Dashboard: http://localhost:9180/ui"
echo "  Logto OIDC: http://localhost:9080/logto/oidc/.well-known/openid-configuration"
