# 第一个 API 调用

> 目标：注册/登录 Logto → 拿到 access token → 经 APISIX 调用 PostgREST 视图与 RPC。

## 链路全景

```text
浏览器 / curl
   │ ① 登录（OIDC，Logto :3001）
   ▼
Logto（签发 JWT；Console :3002 管理）
   │ ② Authorization: Bearer <JWT>
   ▼
APISIX :9080（jwt-auth 验签 + 路由/重写 + CORS）
   ▼
PostgREST :3100（api_v1_platform schema；PGRST_JWT_SECRET=Logto JWKS；DB 角色取 .pg_role）
   ▼
pgBouncer :6432 → PostgreSQL（RLS / has_permission 判定）
```

## 1. Logto 注册/登录入口与端口

| 入口 | 地址 | 说明 |
| --- | --- | --- |
| Admin Console | http://localhost:3002 | 首次启动创建管理员（OSS 单管理员）；在此建应用/用户/角色/组织/webhook |
| Core / OIDC | http://localhost:3001 | `/oidc/.well-known/openid-configuration`、`/oidc/jwks`、`/oidc/auth`、`/oidc/token` |
| 经 APISIX 同源代理 | http://localhost:9080/logto/... | 前端 SDK endpoint，规避 CORS（`init-apisix-routes.sh` 的 logto_proxy 路由） |
| APISIX JWKS 代理 | http://localhost:9080/.well-known/jwks | 公开路由 → app-logto:3001 |

演示账号：在 Console 创建用户，或参考 `scripts/e2e-test.sh` 头部的默认值（`E2E_USER=admin` / `E2E_PASSWORD=Admin@112104`、`CLIENT_ID=lbrkbi552ndpp22o339p4`、`ORG_ID=fmr1j72k3htk`、`RESOURCE=https://default.logto.app/api`、`REDIRECT_URI=http://localhost:5173/auth/callback`）——它们针对某个具体 Logto 实例，需与你自己的配置一致。

## 2. 获取 access token（OIDC Authorization Code + PKCE）

要点（代码事实，见 `scripts/e2e-test.sh` 的 `logto_login()`）：

- token 交换必须带 **`resource`** 参数（RFC 8707）；不带时 Logto 签发 opaque token，APISIX/PostgREST 无法验签。
- scope 需要 `openid profile offline_access urn:logto:scope:organizations`；组织 token 需在 consent 步骤提交 `organizationIds`。
- Logto Custom Token Claims 脚本注入 `roles`（字符串数组）与 `pg_role`（PostgREST DB 角色映射）——这是 RLS 与角色判定的数据源。
- JWT 算法：开发环境为 HS256（`JWKS_JSON` 对称密钥）；staging/production 应指向 Logto JWKS 公钥（RS256 口径，见 init-apisix-routes.sh；compose 与 .env.staging/.production 注释写 ES384，口径不一致——需以 Logto 实际配置核实）。

curl 流程（与浏览器等价；完整实现见 e2e-test.sh）：

```bash
LOGTO=http://localhost:3001
CLIENT_ID=<你的应用 ID>
REDIRECT_URI=http://localhost:5173/auth/callback
RESOURCE=https://default.logto.app/api
VERIFIER=$(python3 -c "import secrets; print(secrets.token_urlsafe(64))")
CHALLENGE=$(python3 -c "
import hashlib, base64
d = hashlib.sha256('$VERIFIER'.encode()).digest()
print(base64.urlsafe_b64encode(d).rstrip(b'=').decode())")
SCOPE='openid%20profile%20offline_access%20urn:logto:scope:organizations'

# ① 打开授权页（浏览器人工登录，或按 e2e 用 interaction API 模拟）
curl -s -c c.txt -o /dev/null \
  "$LOGTO/oidc/auth?client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&response_type=code&scope=$SCOPE&state=s&code_challenge=$CHALLENGE&code_challenge_method=S256&resource=$RESOURCE&prompt=consent"

# ② 登录 + consent 后回调拿到 ?code=...
# ③ 换 token（必须带 resource）
curl -s -X POST "$LOGTO/oidc/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&code=$CODE&code_verifier=$VERIFIER&resource=$RESOURCE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
```

> 前端接入：仓库暂无前端工程；若引入 Logto SDK，endpoint 指向 `http://localhost:9080/logto`（同源代理）。

## 3. 网关入口与鉴权头

- 业务流量入口：**APISIX http://localhost:9080**，请求头 `Authorization: Bearer <access_token>`。
- 直接调试 PostgREST：**http://localhost:3100**（compose 映射 3100→3000，同样需要 Bearer）。暴露 schema 为 `api_v1_platform`，因此路径即视图名/RPC 名（如 `/role`、`/v_user_list`、`/rpc/get_current_user`）。
- `gateway/.env.example` 的 `PGRST_PORT` 已统一为 **3100**（2026-08-27），与 compose 的 `3100:3000` 映射一致；3001/3002 已让给 Logto。

APISIX 路由（`scripts/init-apisix-routes.sh`，代码事实）：

| 路径 | 优先级 | 鉴权 | 上游/动作 |
| --- | --- | --- | --- |
| `/.well-known/jwks` | 100 | 公开 | app-logto:3001 |
| `/logto/*` | 60 | 公开 | 重写去前缀 → app-logto:3001 |
| `/rpc/webhook_logto` | 95 | POST + HMAC 验签（无 jwt-auth） | app-postgrest:3000 |
| `/rpc/ensure_user` | 80 | jwt-auth | app-postgrest:3000 |
| `/api/v1/platform/*` | 50 | jwt-auth | 重写 `^/api/v1/platform/(.*)` → `/$1` |
| `/rpc/*` | 40 | jwt-auth | app-postgrest:3000 |
| `/*` | 10 | jwt-auth | 兜底 → PostgREST |

> 路由初始化见 [一键搭建本地开发环境](一键搭建本地开发环境.md) 第 3 步；`make dev` 自动运行 Logto 版 `scripts/init-apisix-routes.sh`（2026-08-19 起）。
> 注：`api_v1_sales` / `api_v1_inventory` 路由已于 2026-08-15 退役（init-apisix-routes.sh 不再创建，且开头会清理其残留）。

## 4. 示例：查询一个公开视图（经 APISIX）

```bash
TOKEN=<你的 access token>

# 角色镜像目录（api_v1_platform.role）
curl -s 'http://localhost:9080/api/v1/platform/role?select=role_code,role_name&limit=5' \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

# 用户列表视图（api_v1_platform.v_user_list；RLS 只返回当前用户可见行）
curl -s 'http://localhost:9080/api/v1/platform/v_user_list?select=id,username,email&limit=5' \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

# 直连 PostgREST（同一 token；schema 即 api_v1_platform）
curl -s 'http://localhost:3100/role?select=role_code,role_name&limit=5' \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
```

> 说明：`users` / `v_user_list` 的数据源是 platform 的 `users`（Logto 镜像）+ `user_profile`（业务档案）直接投影；`password_hash` 恒 NULL——密码由 Logto 管理，库内不存明文。原 `platform.sys_user` 兼容视图已于 2026-08-20 移除。

## 5. 示例：调用一个 RPC

RPC 走 `POST /rpc/<name>`；经 APISIX 可用 `/api/v1/platform/rpc/<name>` 或 `/rpc/<name>`（都带 jwt-auth）。

```bash
# 当前登录用户（JWT claims → users/user_profile/tenants 镜像；无参）
curl -s -X POST 'http://localhost:9080/api/v1/platform/rpc/get_current_user' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -m json.tool

# 用户菜单树（前端初始化时调用；无参）
curl -s -X POST 'http://localhost:9080/api/v1/platform/rpc/get_user_menu' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -m json.tool

# 带参数示例：分页搜索用户（函数名 search_users，形参见 db/api_v1/platform/rpc/rpc_search_users.sql）
curl -s -X POST 'http://localhost:9080/rpc/search_users' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_query":"admin","p_limit":20,"p_offset":0}' | python3 -m json.tool
```

> RPC 清单与参数见 [RPC 参考](../06-API参考/RPC清单.md) 与 Swagger（http://localhost:8082）。RPC 形参名必须与 SQL 函数签名一致（PostgREST 按参数名匹配，错误会 400/404）。

## 6. 常见报错与含义

| 状态码 | 场景 | 含义与排查 |
| --- | --- | --- |
| 401 | APISIX jwt-auth / PostgREST | 未认证：无 `Authorization` 头、token 过期/无效/签名不符。检查 token 是否为 JWT（带 resource 签发）、`gateway/.env` 的 `JWKS_JSON` 是否为 Logto JWKS |
| 403 | PostgREST | 认证通过但授权不足：PG 角色（`pg_role`）无权限、RLS 过滤、RPC 内 `has_permission()` 拒绝。检查角色映射/角色绑定/RLS 策略 |
| 404 | APISIX → PostgREST | 路由或对象不存在：视图/RPC 不在 `api_v1_platform`、schema 未暴露、路径重写错误。对照 OpenAPI 与路由表 |
| 400 | PostgREST | 请求体/参数与函数签名不符（常见于 RPC 形参名错误） |
| 429 | APISIX | 限流（当前 compose 未配置 limit-req，一般不出现） |

补充：

- RLS 过滤是静默的：查询返回 `[]`（200）而非报错。
- 直连 PostgREST（3100）时可见错误码：`PGRST101`（连库失败）、`PGRST115`（角色不存在）、`PGRST104`（schema 不存在）。
- token 中 `pg_role` claim 缺失或映射错误时，PostgREST 会以 `web_anon` 处理，通常表现为 403 或空结果。

> 排障细节见 [常见问题排查](常见问题排查.md)。

---

> 参考：[网关路由](../06-API参考/网关路由.md) · [PostgREST 使用指南](../06-API参考/PostgREST使用指南.md) · [RPC 参考](../06-API参考/RPC清单.md) · [认证与授权设计](../04-架构/认证授权设计.md) · [E2E 集成测试](../07-测试/E2E集成测试.md)