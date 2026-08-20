# PostgREST 使用指南

PostgREST 是本项目对外 API 层的执行引擎：它把 PostgreSQL（public schema 的业务逻辑 + api_v1_* 暴露层）自动映射为 RESTful API，是「数据库即后端」架构的 HTTP 出口。本文以当前代码为准（`gateway/postgrest/postgrest.conf` + `gateway/docker-compose.yml` 环境变量），介绍入口、鉴权、查询语法、RPC 调用与排障。

## 入口与端口

PostgREST 以 Docker 容器运行（`gateway/docker-compose.yml` 中 `postgrest` 服务，镜像 `postgrest/postgrest:v14.15`）：

| 项 | 值 | 来源 |
|:---|:---|:---|
| 容器内监听 | `0.0.0.0:3000` | `postgrest.conf` `server-host/server-port` |
| 宿主机映射 | `3100:3000` | `docker-compose.yml` |
| OpenAPI / 根路径 | `http://localhost:3100/` | 返回 OpenAPI JSON |
| Swagger UI | `http://localhost:8082/` | 独立 `swagger-ui` 容器 |
| 数据库连接 | `postgres://authenticator:***@host.docker.internal:6432/app_db?sslmode=disable`（经 Pigsty pgBouncer） | compose 环境变量 |
| 匿名角色 | `web_anon` | `db-anon-role` |

> ⚠️ 配置优先级（运行态权威）：PostgREST 环境变量（compose 的 `PGRST_*`）覆盖配置文件。**运行态以 `gateway/docker-compose.yml` 为权威**，`gateway/postgrest/postgrest.conf` 仅是参考文件（2026-08-19 已与运行态对齐：单 schema api_v1_public、`.pg_role`、无 pre-request）。另外 `gateway/.env.example` 与 `scripts/verify-stack.sh` 仍写着 `PGRST_PORT=3001`，那是 Logto 时代的旧值——**当前 PostgREST 宿主端口是 3100**（3001 已让给 Logto core）。

### 实际生效的关键配置（compose 环境变量为准）

| 配置 | compose 值 | conf 文件值 | 说明 |
|:---|:---|:---|:---|
| `PGRST_DB_SCHEMAS` | `api_v1_public` | `api_v1_public`（2026-08-19 已对齐） | **以 compose 为运行态权威**：只暴露 api_v1_public 单 schema（sales/inventory 已退役，见下节） |
| `PGRST_DB_EXTRA_SEARCH_PATH` | `api_v1_public,public` | `api_v1_public, public`（2026-08-19 已对齐） | 函数解析路径，public 用于调用底层逻辑 |
| `PGRST_DB_PRE_REQUEST` | `""`（空） | `api_v1_public.check_token_blacklist` | **已退役**：`db/init/02-schemas.sql` 明确 token 黑名单/会话吊销交给 Logto（D12），pre-request 清空 |
| `PGRST_JWT_SECRET` | `${JWKS_JSON}` | 同 | JWT 验签密钥：开发环境 = HS256 对称密钥（JWKS_JSON 的 oct key）；staging/production = Logto JWKS 公钥（RS256），算法口径见「鉴权」节 |
| `PGRST_JWT_ROLE_CLAIM_KEY` | `.pg_role` | `.pg_role`（2026-08-19 已对齐） | 运行态以 `.pg_role` 为准（Logto Custom Token Claims 脚本注入） |
| `PGRST_OPENAPI_SERVER_PROXY_URI` | `http://localhost:3100` | `http://localhost:3000` | Swagger 展示用 |
| `PGRST_CORS_ORIGINS` | `*` | `""` | CORS 由 APISIX 全局规则处理；Swagger 浏览器直连拉 spec 需要 |

其他固定项：`max-rows = 1000`、`db-aggregates-enabled = true`、`pre-error-extended = true`（错误带 details/hint）、`db-tx-end = commit`、`log-level = warn`。

## 鉴权：Authorization: Bearer

认证链路：**Logto 签发 access token（OIDC）→ APISIX `jwt-auth` 验签放行 → PostgREST 再用同一 `JWKS_JSON` 验签**，并把 JWT claims 注入 `request.jwt.claims`（PostgREST 自动完成）。

JWT 算法口径：开发环境为 **HS256**（`gateway/.env.example` 的 JWKS_JSON 是 oct 对称密钥，PostgREST 与 APISIX jwt-auth 同源）；staging/production 指向 **Logto JWKS 公钥 RS256**（历史 Logto 方案文档（已归档）与 `scripts/init-apisix-routes.sh` 口径）。⚠️ compose 注释与 `.env.staging/.production` 注释写的是 **ES384**——口径不一致，实际算法需以 Logto 配置为准（TODO 核实）。

```bash
curl -H 'Authorization: Bearer <logto-access-token>' \
  'http://localhost:3100/users'
```

- 未带 / 无效 token → PostgREST 按 `web_anon` 执行。`web_anon` 只被授予 `USAGE ON SCHEMA api_v1_public`，没有任何表权限（`db/init/02-schemas.sql`），因此匿名访问一律 401/403。
- 有效 token → PostgREST 根据 `pg_role` claim 切换到对应 PG 角色（super_admin / role_admin / role_editor / role_guest），并暴露 claims：
  - `sub` → `current_user_id()`
  - `organization_id`（组织 token 内置 claim）→ `current_tenant_id()`，供 RLS 租户隔离
  - `roles`（自定义脚本注入的角色名数组）→ `current_user_roles()` / `is_super_admin()` / `has_permission()`

角色映射详见 [认证与授权设计](../04-架构/auth-design.md) 与 [Logto Webhook 接入](./logto-webhook.md)（`pg_role` 注入脚本在 `scripts/phase2/init-logto.py` 的 `CLAIMS_SCRIPT`）。

## 暴露范围：api_v1_public（运行态单 schema）

**Schema 布局（`db/init/02-schemas.sql`）**：`public`（核心业务：表/函数/触发器/RLS）、`api_v1_public`（对外暴露层：视图/RPC，027 定稿名）、`net`（pg_net 宿主）。**不存在 extensions schema**（早先方案的 extensions 域未落地）。

**运行态（compose 为权威）**：`PGRST_DB_SCHEMAS=api_v1_public`——PostgREST 实际只暴露 `api_v1_public` 单 schema，`PGRST_DB_EXTRA_SEARCH_PATH=api_v1_public,public`（public 仅供函数解析）。`gateway/postgrest/postgrest.conf` 是**参考文件**（2026-08-19 已对齐运行态：`db-schemas = "api_v1_public"`、`jwt-role-claim-key = .pg_role`、无 pre-request；sales/inventory schema 未在 02-schemas.sql 创建、对应 URL 路由已于 2026-08-15 退役）。`db/api_v1/` 目录按 `_shared` / `public` 分域，**当前仅 `public/` 下有实体 SQL**（44 个 RPC + 29 个视图）。

其中：

- **视图**（29 个，`db/api_v1/public/views/*.sql`）：视图名 = 底层表名（`users`、`department`、`role`、`iam_menu`、`dict_type`、`login_log`、`audit_log`、`cron_job_log` 等）+ `v_*` 明细/聚合视图（`v_user_list`、`v_role_list`、`v_dict_list`、`v_audit_log_detail` 等）。这些是只读投影：`users`/`role` 等 Logto 镜像表只允许经 sync_*（SECURITY DEFINER）与对账通道写入。
- **RPC**（44 个，`db/api_v1/public/rpc/*.sql`）：对外暴露为 `/rpc/<name>`，全部 `GRANT EXECUTE ... TO authenticated`（仅 `webhook_logto` 授给 `web_anon`）。完整索引见 [RPC 清单](./rpc-reference.md)。
- **授权矩阵**见 `db/api_v1/public/privileges/zz_grant_all.sql`：authenticated 只读基础视图；role_guest 只读全部；role_editor 只读；role_admin 对业务自主表（department/iam_menu/iam_role_menu/app_config）可 INSERT/UPDATE；super_admin 全权（镜像表仅 SELECT，写入收敛到 sync_*/JIT/对账）。
- **兼容视图已移除**（2026-08-20）：`public.sys_user` / `public.casbin_rule` 已删除（不再借鉴 Casbin 权限模型），用户查询直接走 `public.users` + `public.user_profile`。

- **视图**（29 个，`db/api_v1/public/views/*.sql`）：视图名 = 底层表名（`users`、`department`、`role`、`iam_menu`、`dict_type`、`login_log`、`audit_log`、`cron_job_log` 等）+ `v_*` 明细/聚合视图（`v_user_list`、`v_role_list`、`v_dict_list`、`v_audit_log_detail` 等）。这些是只读投影：`users`/`role` 等 Logto 镜像表只允许经 sync_*（SECURITY DEFINER）与对账通道写入。
- **RPC**（44 个，`db/api_v1/public/rpc/*.sql`）：对外暴露为 `/rpc/<name>`，全部 `GRANT EXECUTE ... TO authenticated`（仅 `webhook_logto` 授给 `web_anon`）。完整索引见 [RPC 清单](./rpc-reference.md)。
- 授权矩阵见 `db/api_v1/public/privileges/zz_grant_all.sql`：authenticated 只读基础视图；role_guest 只读全部；role_editor 只读；role_admin 对业务自主表（department/iam_menu/iam_role_menu/app_config）可 INSERT/UPDATE；super_admin 全权（镜像表仅 SELECT，写入收敛到 sync_*/JIT/对账）。

## 查询语法

所有操作符示例假设 `Authorization: Bearer $TOKEN`。

### 过滤（水平过滤）

| 操作符 | 含义 | 示例 |
|:---|:---|:---|
| `eq` / `neq` | 等于 / 不等于 | `?tenant_id=eq.<org_id>`、`?is_active=neq.false` |
| `gt` / `gte` / `lt` / `lte` | 大于 / 大于等于 / 小于 / 小于等于 | `?created_at=gte.2026-08-01T00:00:00Z` |
| `like` / `ilike` | 模糊匹配（`*` 为通配） | `?username=ilike.*admin*` |
| `in` | 包含于 | `?id=in.(a,b,c)` |
| `is` | NULL 判断 | `?deleted_at=is.null` |
| `not.` | 取反 | `?status=not.eq.disabled` |

多条件之间是 AND；`or=(...)` 可表达 OR 组合：

```bash
curl -H "Authorization: Bearer $TOKEN" \
  'http://localhost:3100/department?tenant_id=eq.t1&is_active=eq.true&order=sort_order.asc'
```

### 列选择

```bash
curl -H "Authorization: Bearer $TOKEN" \
  'http://localhost:3100/v_user_list?select=id,username,email,tenant_name'
```

### 排序与分页

```bash
# 排序 + limit/offset 分页
curl -H "Authorization: Bearer $TOKEN" \
  'http://localhost:3100/audit_log?order=created_at.desc&limit=20&offset=0'

# 精确计数（配合 Prefer: count=exact 返回 X-Total-Count 头）
curl -H "Authorization: Bearer $TOKEN" -H 'Prefer: count=exact' \
  'http://localhost:3100/v_user_list?is_active=eq.true'
```

全局 `max-rows = 1000`：单次返回超过 1000 行会返回 206 截断，请用分页。也支持 `Range: 0-99` / `Content-Range` 头分页（由 APISIX 全局 CORS `expose_headers` 暴露 `X-Total-Count, Content-Range`）。

### 嵌入（embed / 垂直过滤）

`?select=parent,children(*)` 式嵌入依赖外键关系（PostgREST 自动识别 FK）。api_v1_public 视图大多是扁平投影，跨 schema（public）对象不会出现在 OpenAPI 中，嵌入主要用于视图内部的 FK（如 `v_user_list` 已 JOIN 好租户/部门，一般无需再嵌）。需要复杂聚合时优先使用 RPC。

## RPC 调用

函数暴露为 `/rpc/<name>`，参数名即 SQL 参数名（本项目统一 `p_` 前缀）：

```bash
# POST 调用（推荐）
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_user_id": "abc123"}' \
  'http://localhost:3100/rpc/rpc_get_user_profile'

# 无参 RPC（GET 也可）
curl -H "Authorization: Bearer $TOKEN" 'http://localhost:3100/rpc/get_current_user'
```

- 返回 `json` 的函数直接返回 JSON 对象；返回 `TABLE(...)` 的函数（如 `rpc_list_cron_jobs`）返回 JSON 数组。
- 函数内 `has_permission('public:xxx')` 或 `require_super_admin()` 不通过时抛 `42501 permission denied`。
- 经网关访问时路径为 `http://localhost:9080/rpc/<name>`（`/rpc/*` 路由，jwt-auth 保护）；webhook 入口 `POST /rpc/webhook_logto` 例外（见 [Logto Webhook 接入](./logto-webhook.md)）。

## OpenAPI / Swagger

- PostgREST 自动生成 OpenAPI：`curl http://localhost:3100/`（内容为 spec JSON，含全部视图与 RPC，函数/视图的 `COMMENT ON` 会作为描述）。
- Swagger UI：`http://localhost:8082/`，浏览器端从 `API_URL`（compose 默认 `http://localhost:${PGRST_PORT:-3001}/`）拉取 spec。**注意**：`.env.example` 的 `PGRST_PORT=3001` 与当前 3100 端口映射不一致，部署时 `gateway/.env` 必须设置 `PGRST_PORT=3100`，否则 Swagger 拉取失败（TODO：`.env.example` 与 `verify-stack.sh` 中的 3001 旧值待同步）。
- 用 "Try it out" 可在线测试接口；Swagger 按 schema 分组为 Tag，运行态（compose 权威）仅 `api_v1_public` 一个 tag。

## 常见错误与排查

| HTTP | 场景 | 排查 |
|:---:|:---|:---|
| 401 | 未带 token / token 验签失败 / 匿名角色无权限 | 确认 token 由 Logto 签发、未过期；APISIX 与 PostgREST 使用同一份 `JWKS_JSON` |
| 403 | 角色无操作权限（`web_anon` 或 PG 角色 GRANT 不足） | 检查 `zz_grant_all.sql` 授权；`has_permission` 抛 `42501 permission denied` 也表现为 403 |
| 404 | 路径不存在（视图名写错 / RPC 名或参数签名不匹配） | PostgREST 对函数按「函数名 + 参数类型」匹配，参数名对但类型不匹配会 404 |
| 400 | 过滤/JSON body 语法错误、函数入参校验失败（如 `22023`、`P0002`） | 看响应体 `details` / `hint`（`pre-error-extended = true` 已开启） |
| 206 | 超过 `max-rows = 1000` 截断 | 加分页（limit/offset 或 Range 头） |
| 42501 / P0002 / 22023 | SQLSTATE 直传 | 分别是「权限拒绝」「记录不存在」「参数非法」，RPC 内 `RAISE EXCEPTION` 产生，message 即错误说明 |

PostgREST 错误响应格式（extended）：

```json
{
  "code": "PGRST204",
  "message": "The request resulted in no rows",
  "details": "When the request is expected to return 0 results",
  "hint": null
}
```

日志：`docker logs -f app-postgrest`（`log-level = warn`，调 `PGRST_LOG_LEVEL` 可放大）；健康检查 `curl -s http://localhost:3100/ | wc -c`（应 >2000 字符）。

---

> 参考：[RPC 清单](./rpc-reference.md) · [网关路由](./gateway-routing.md) · [Logto Webhook 接入](./logto-webhook.md) · [认证与授权设计](../04-架构/auth-design.md) · [数据流](../04-架构/data-flow.md)
