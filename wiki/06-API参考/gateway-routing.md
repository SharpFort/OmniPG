# 网关路由

APISIX 是本项目唯一对外的 API 网关（入口 9080），负责 JWT 验签、webhook 验签、路径重写、CORS 与上游转发；PostgREST 只在容器网络内被 APISIX 访问（宿主 3100 仅用于调试/OpenAPI）。本文档以当前代码为准：`gateway/docker-compose.yml`、`gateway/apisix/config.yaml`、`scripts/init-apisix-routes.sh`。

## 配置位置与运行模式

| 文件 | 作用 | 状态 |
|:---|:---|:---|
| `gateway/apisix/config.yaml` | APISIX **启动配置**（traditional 模式、etcd 地址、Admin Key、Dashboard/Status/Control 开关） | ✅ 当前生效 |
| `gateway/apisix/apisix.yaml` | standalone 模式的**历史路由留档**（文件头注明不再被加载） | ⚠️ 仅参考，勿改 |
| `gateway/docker-compose.yml` | 网关栈容器编排（etcd / apisix / postgrest / swagger-ui / logto） | ✅ 当前生效 |
| `scripts/init-apisix-routes.sh` | **目标**路由初始化脚本（Logto 版：RS256 JWKS、webhook 验签、业务路由）——本页路由表的来源 | 🎯 目标架构；尚未接入 Makefile/部署链（仅 `e2e-test.sh` 注释提及），新环境需手动执行或待收敛接线 |
| `scripts/setup_apisix.sh` | 早期路由初始化脚本（Casdoor/HS256 时代，引用 `app-casdoor:8000`） | ⚠️ 旧残留；但 Makefile `dev`、`deploy-all.sh`、`deploy-gateway.sh` / `deploy-gateway.yml` 仍调用它——新旧并存，待收敛 |

关键运行模式（`config.yaml`）：

- `deployment.role: traditional`，`config_provider: etcd`——**路由/插件/上游全部存 etcd**，经 Admin API 管理；不读 `apisix.yaml`。
- etcd 为 compose 内 `app-etcd`（`http://app-etcd:2379`），**不映射宿主端口**（宿主 2379 被 Pigsty etcd 占用）。
- Admin API 需要 `X-API-KEY`（`APISIX_ADMIN_KEY`，由 `gateway/.env` 注入）；开发环境 `allow_admin: 0.0.0.0/0`，生产必须收窄。
- 内置 Dashboard（`enable_admin_ui: true`）、Status API（7085）、Control API（9092，内部运维勿暴露公网）。

## 对外端口与服务映射

来源：`gateway/docker-compose.yml`（ports 段）+ Pigsty 侧约定：

| 宿主端口 | 服务 | 容器内 | 说明 |
|:---:|:---|:---|:---|
| 9080 | APISIX 数据面 HTTP | 9080 | 所有业务流量入口 |
| 9443 | APISIX 数据面 HTTPS | 9443 | 预留 |
| 9180 | APISIX Admin API + Dashboard | 9180 | REST 管理接口；浏览器 `http://localhost:9180/ui` |
| 7085 | APISIX Status API | 7085 | 健康探针 `GET /status` → `{"status":"ok"}` |
| 3100 | PostgREST | 3000 | 调试/OpenAPI 直连；**业务必须走 9080** |
| 8082 | Swagger UI | 8080 | `API_URL` 指向 PostgREST（${PGRST_PORT}） |
| 3001 | Logto Core / OIDC / Management API | 3001 | 签发 token、`/oidc/.well-known/openid-configuration` |
| 3002 | Logto Admin Console | 3002 | 管理员控制台 |
| —（不映射） | etcd | 2379 | 容器间 `app-etcd:2379` |
| 6432 | pgBouncer（宿主 Pigsty） | — | PostgREST/Logto 经 `host.docker.internal:6432` 连接 |

> ⚠️ 历史文档（服务访问速查手册，已归档）与 `scripts/verify-stack.sh`、`scripts/start.sh` 仍写 PostgREST=3001、Casdoor=8000——那是 Logto 迁移前的旧值。**当前以本表为准**：3001 是 Logto，PostgREST 是 3100，Casdoor 已移除。

## 路由表（当前，由 `scripts/init-apisix-routes.sh` 写入）

路由优先级：数字越大越先匹配（相同 URI 前缀下 webhook 路由 `/rpc/webhook_logto` 优先级 95 高于 `/rpc/*` 的 40，因此不会被 jwt-auth 拦截）。

| 路由 ID | 路径 | 方法 | 优先级 | 上游 | 插件 | 说明 |
|:---|:---|:---|:---:|:---|:---|:---|
| `logto_jwks` | `/.well-known/jwks` | 全部 | 100 | `app-logto:3001` | 无（公开） | Logto JWKS 公钥端点代理（OIDC 客户端拉公钥） |
| `logto_proxy` | `/logto/*` | 全部 | 60 | `app-logto:3001` | `proxy-rewrite`：`^/logto/(.*)` → `/$1` | Logto 同源代理（前端 SDK 用 `http://localhost:9080/logto` 规避 CORS） |
| `webhook_logto` | `/rpc/webhook_logto` | POST | 95 | `app-postgrest:3000` | `serverless-pre-function`：HMAC-SHA256 验签（`logto-signature-sha-256` vs rawBody） | **无 jwt-auth**（web_anon 可调）；**禁止叠加 request-validation**（JSON 重排会破坏 rawBody 签名）；缺 `LOGTO_WEBHOOK_SIGNING_KEY` 时脚本 exit 1（fail-closed） |
| `ensure_user` | `/rpc/ensure_user` | POST | 80 | `app-postgrest:3000` | `jwt-auth`（`key_claim_name: sub`） | 登录 JIT 建档兜底（见 [Logto Webhook 接入](./logto-webhook.md)） |
| `api_v1_public` | `/api/v1/sys/*` | 全部 | 50 | `app-postgrest:3000` | `proxy-rewrite`：`^/api/v1/sys/(.*)` → `/$1`；`jwt-auth`（`key_claim_name: sub`） | 视图/业务 API：`/api/v1/sys/users` → PostgREST `/users` |
| `rpc_all` | `/rpc/*` | 全部 | 40 | `app-postgrest:3000` | `jwt-auth`（`key_claim_name: sub`） | 全部 RPC（`webhook_logto` 因优先级更高先命中） |
| `catch_all` | `/*` | 全部 | 10 | `app-postgrest:3000` | `jwt-auth`（`key_claim_name: sub`） | 兜底：未匹配路径进 PostgREST 由其返回 404 |

历史差异（旧 `scripts/setup_apisix.sh` / `apisix.yaml`）：曾有 `api_v1_sales`、`api_v1_inventory`（`/api/v1/sales/*`、`/api/v1/inventory/*`）与 Casdoor JWKS/`user_login_sso`/`refresh_token_rtr` 路由，**均已退役**（2026-08-15 起 sales/inventory 测试模块移除；登录改为 Logto OIDC）。`init-apisix-routes.sh` 第 0 步会幂等删除 Casdoor 时代残留路由。

## 已知不一致 / 待收敛（新旧并存）

当前仓库中网关相关配置存在**新旧并存**，写代码/排障时务必区分：

| 对象 | 现状 | 判定 |
| --- | --- | --- |
| `gateway/apisix/apisix.yaml` | standalone 时代留档，文件头已注明“不再被加载”（traditional 模式路由存 etcd）；内容为 Casdoor 时代路由（`/rpc/user_login_sso`、`/rpc/refresh_token_rtr`、`/well-known/jwks`、`/api/v1/sales/*`、`/api/v1/inventory/*`、`api_v1_sys` 重写） | ❌ 过时残留，勿当现行路由表 |
| `scripts/setup_apisix.sh` | Casdoor 时代初始化脚本（jwks 上游指向已死的 `app-casdoor:8000`、`user_login_sso`、`refresh_token_rtr`、sales/inventory 重写）；但 Makefile `dev` 目标、`deploy-all.sh`、`deploy-gateway.sh`（及 `deploy-gateway.yml` 工作流）仍调用它 | ⚠️ 部署链在用旧脚本，与 Logto 架构不一致，待收敛 |
| `scripts/init-apisix-routes.sh` | Logto 时代目标脚本（本页路由表的来源：logto_jwks / logto_proxy / webhook_logto / ensure_user / api_v1_public / rpc_all / catch_all 共 7 条）；仓库内未被 Makefile/部署链调用，仅 `e2e-test.sh` 注释提及 | 🎯 预期新脚本：新环境请手动执行，并把它接入部署链（TODO） |
| PostgREST schema 配置 | **运行态以 `gateway/docker-compose.yml` 为权威**：`PGRST_DB_SCHEMAS=api_v1_public`（单 schema）、`PGRST_JWT_ROLE_CLAIM_KEY=.pg_role`、`PGRST_DB_EXTRA_SEARCH_PATH=api_v1_public,public`、`PGRST_MAX_ROWS=1000`、`PGRST_DB_PRE_REQUEST` 已清空、`PGRST_JWT_SECRET=$(JWKS_JSON)`；`gateway/postgrest/postgrest.conf` 仅为参考文件（其 `db-schemas="api_v1_public, api_v1_sales, api_v1_inventory"`、`jwt-role-claim-key=roles[0]`、`db-pre-request=api_v1_public.check_token_blacklist` 与运行态不一致） | ✅ compose 为运行态权威；引用 conf 时须注明“以 compose 为准” |
| `scripts/verify-stack.sh` / `scripts/start.sh` | 仍检查 Casdoor:8000、`user_login_sso`、policy-syncer、路由数=8 等旧项 | ⚠️ 过时，详见 [冒烟验证脚本](../07-测试/verify-scripts.md) |

**Schema 布局（`db/init/02-schemas.sql`）**：`public`（核心业务：表/函数/触发器/RLS）、`api_v1_public`（对外暴露层：视图/RPC，027 定稿名，原 api_v1_sys）、`api_v1_sys`（027 改名链兼容承载，新代码不用）、`net`（pg_net 扩展宿主）；**不存在 extensions schema**。PostgREST 运行态只暴露 `api_v1_public` 单 schema（compose 环境变量权威，见上表）。`db/api_v1/` 目录按 `_shared`/`inventory`/`public` 分域（当前仅 `public/` 下有实体 SQL 文件；sales/inventory 模块 2026-08-15 退役，其 URL 前缀路由已从 Logto 版路由集移除，按需重建）。URL 前缀 `/api/v1/sys/*` 重写 `^/api/v1/sys/(.*)` → `/$1`，落到 `api_v1_public`。

## 鉴权与安全插件

### jwt-auth（业务路由）

`scripts/init-apisix-routes.sh` 步骤 2 从 Logto OIDC discovery（`http://localhost:3001/oidc/.well-known/openid-configuration` → `jwks_uri`）拉取 RS256 JWKS，写入 Admin API：

```bash
curl -s -X PUT http://localhost:9180/apisix/admin/plugin_metadata/jwt-auth \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{"algorithm":"RS256","key":"<JWKS_JSON字符串>"}'
```

业务路由的 `jwt-auth` 配置 `key_claim_name: "sub"`（把 JWT 的 `sub` 当 consumer 标识）。验签通过后原样转发 `Authorization` 头给 PostgREST 二次验签。

> 算法口径：开发环境 `gateway/.env` / `.env.development` 的 `JWKS_JSON` 默认是 **HS256 对称密钥**（kty=oct，`PGRST_JWT_SECRET=$(JWKS_JSON)` 直接作为 PostgREST 验签密钥）；staging/production 应指向 Logto JWKS 公钥，`init-apisix-routes.sh` 按 **RS256** 配置 APISIX jwt-auth 元数据。`gateway/docker-compose.yml` 注释与 `.env.staging`/`.env.production` 中出现 ES384 字样，口径不一致——最终以 Logto 实际签发的 JWKS/配置为准（TODO 核实）。

### webhook 验签（serverless-pre-function）

`/rpc/webhook_logto` 路由挂载 Lua 函数（`init-apisix-routes.sh` 生成）：

- 读取原始请求体（大 body 落到临时文件时用 `ngx.req.get_body_file()` 回退读取）；
- 取请求头 `logto-signature-sha-256`，与 `HMAC-SHA256(signingKey, rawBody)` 的 hex 结果比较；
- 不一致或缺头 → 直接 `ngx.exit(401)`；
- signingKey 来自 `gateway/.env` 的 `LOGTO_WEBHOOK_SIGNING_KEY`，缺失时脚本 **exit 1 拒绝部署**（fail-closed，N15 修复）。

### 全局 CORS（global_rules/1）

```json
{
  "plugins": {
    "cors": {
      "allow_origins": "*",
      "allow_methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "allow_headers": "Authorization,Content-Type,X-Requested-With,logto-signature-sha-256",
      "expose_headers": "X-Total-Count,Content-Range",
      "max_age": 3600,
      "allow_credentials": true
    }
  }
}
```

注意：`allow_headers` 显式包含 `logto-signature-sha-256`；`expose_headers` 暴露 PostgREST 分页头（X-Total-Count / Content-Range）。

### 限流 / 安全头（当前状态）

- **限流（limit-req）**：历史方案文档（10-APISIX路由批量配置，已归档）曾设计全局 `limit-req`（rate=100/burst=50），**未落入当前 `init-apisix-routes.sh`**——当前 global_rules 只有 CORS。如需限流请新增 global_rule 或路由级插件。
- **安全头**（real-ip、http-to-https、UA 校验等）：当前未配置。TODO：生产环境需补充（参照 10 号文档 §10 生产注意事项）。

## 新增一条路由的操作步骤

以新增独立端点 `/public/foo` 为例：

1. **确认走 Admin API（etcd）**，不要改 `apisix.yaml`（standalone 留档，不生效）。
2. 用 PUT 创建路由（幂等，同 ID 覆盖）：

```bash
curl -s -X PUT http://localhost:9180/apisix/admin/routes/public_foo \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{
    "uri": "/public/foo",
    "methods": ["GET"],
    "upstream": {"type": "roundrobin", "nodes": {"app-postgrest:3000": 1}},
    "priority": 60
  }'
```

3. 若需要 JWT 保护，加 `"plugins": {"jwt-auth": {"key_claim_name": "sub"}}`；若需要路径重写，加 `proxy-rewrite` 的 `regex_uri`；若需要签名校验（webhook 类），参考 `webhook_logto` 的 serverless-pre-function 写法。
4. 验证：

```bash
curl -s http://localhost:9180/apisix/admin/routes -H "X-API-KEY: $APISIX_ADMIN_KEY"   # 列表确认
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9080/public/foo             # 数据面实测
```

5. 需要长期固化的路由，**同步写进 `scripts/init-apisix-routes.sh`**（第 4 步 put 段），保证新环境一键重建。

路由优先级注意：`/rpc/webhook_logto` 的 95 必须高于 `/rpc/*` 的 40；更具体路径的公开路由（如登录回调）应高于 catch_all 的 10。

## 部署与验证

- 部署：`bash scripts/deploy-gateway.sh development`（当前版：检查 APISIX 7085、PostgREST 3100、Logto 3001、Swagger 8082）。⚠️ 该脚本仍含 `docker compose build syncer` 历史遗留段（Go syncer 已退役，webhook 同步在库内完成，见 [Logto Webhook 接入](./logto-webhook.md)），属已知不一致（见上节）。
- 路由初始化（目标脚本）：`bash scripts/init-apisix-routes.sh`（需 `gateway/.env` 已配置 `APISIX_ADMIN_KEY` 与 `LOGTO_WEBHOOK_SIGNING_KEY`）。⚠️ 当前部署链（`deploy-all.sh` / `deploy-gateway.sh` / `deploy-gateway.yml`）仍执行 Casdoor 时代 `setup_apisix.sh`，见上节「已知不一致」。
- 手动验证：
  - `curl -sf http://localhost:7085/status` → `{"status":"ok"}`
  - `curl -sf http://localhost:9180/ui` → HTML（Dashboard）
  - `curl -sf http://localhost:9080/logto/oidc/.well-known/openid-configuration` → Logto 同源代理
  - 无 token 访问 `http://localhost:9080/api/v1/sys/users` → 401（jwt-auth）
- ⚠️ 过时脚本提示：`scripts/start.sh`、`scripts/verify-stack.sh` 仍引用 Casdoor/Syncer/3001 并尝试构建 `syncer` 服务，**不要用于当前架构验证**（CI 的 `syncer-check` job 亦为历史遗留，见 `.github/workflows/ci.yml`）。

---

> 参考：[PostgREST 使用指南](./postgrest.md) · [Logto Webhook 接入](./logto-webhook.md) · [RPC 清单](./rpc-reference.md) · [部署总览](../03-部署指南/deployment-overview.md) · [数据流](../04-架构/data-flow.md)
