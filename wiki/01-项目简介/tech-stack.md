# 技术栈全景

## 组件职责速查表

| 组件 | 职责 | 配置位置 |
| --- | --- | --- |
| **Pigsty** v4.4.0 | 基础设施：PostgreSQL 集群、pgBouncer、Redis、etcd、监控（Grafana/VictoriaMetrics/VictoriaLogs） | `infra/pigsty.yml`、`infra/pigsty.db.yml`、`infra/pigsty.gateway.yml`、`infra/pg_hba.conf` 等 |
| **PostgreSQL** 18 | 唯一数据与逻辑核心：表、视图、RPC、触发器、RLS、扩展 | `db/init/`、`db/migrations/public/`、`db/src/public/`、`db/api_v1/public/` |
| **pgBouncer** | 连接池（PostgREST 经 6432 接入；scram-sha-256） | `infra/pgbouncer.ini`、`infra/userlist.txt` |
| **PostgREST** v14.15 | REST API 层：自动映射 `api_v1_public` 的表视图/RPC，注入 JWT claims，生成 OpenAPI | `gateway/docker-compose.yml`（postgrest 服务环境变量）；参考配置 `gateway/postgrest/postgrest.conf` |
| **APISIX** 3.17.0 | 网关：路由、jwt-auth（Logto JWKS 验签）、webhook HMAC 验签、CORS、限流预留 | `gateway/docker-compose.yml`、`gateway/apisix/config.yaml`；**目标路由集 = `scripts/init-apisix-routes.sh`**（Logto 版）；⚠️ 部署链仍调用旧 `scripts/setup_apisix.sh`（Casdoor 时代残留，见「APISIX：已知不一致/待收敛」） |
| **etcd** 3.5.11 | APISIX 配置中心（traditional 模式，容器内 `app-etcd:2379`） | `gateway/docker-compose.yml`（etcd 服务） |
| **Logto**（自部署 OSS v1.42） | 认证（OIDC）、组织（租户）容器、角色目录 CRUD 与分配、签发 JWT、Webhook 事件推送 | `gateway/docker-compose.yml`（logto 服务，3001 core / 3002 console）；角色/组织/Custom Token Claims 脚本在 Logto Console 配置 |
| **Redis** | Pigsty REDIS 模块（standalone，6379）；预留缓存/限流——当前授权判定无状态、不依赖 Redis | `infra/pigsty.yml`（redis 模块）、`infra/redis.conf` |
| **Swagger UI** v5.2.0 | 交互式 API 文档（从 PostgREST OpenAPI 拉取 spec） | `gateway/docker-compose.yml`（swagger-ui 服务，8082） |
| **dbmate** | 数据库迁移（`migrations/public`） | `db/dbmate.toml`、`Makefile`（`make migrate / migrate-rollback / migrate-status`） |
| **pgTAP + pg_prove** | 数据库单元测试 | `db/tests/`、`Makefile`（`make test-db`） |
| **GitHub Actions** | CI（PR 校验）与 CD（workflow_dispatch 部署） | `.github/workflows/ci.yml`、`deploy-*.yml` |

## 数据库 Schema 布局（以 `db/init/02-schemas.sql` 为准）

| Schema | 内容 | 说明 |
| --- | --- | --- |
| `public` | 核心业务表 + 全部函数/触发器/视图/RLS 策略 | 业务逻辑唯一真相源；镜像表（users/tenants/role/user_tenants/user_role 等）只读投影 |
| `api_v1_public` | 系统管理 API 暴露层：视图 + RPC（`api_v1_public.*`），URL 前缀 `/api/v1/sys/*` 映射至此 | 027 定稿名；**当前 compose 运行态实际暴露**（`PGRST_DB_SCHEMAS=api_v1_public`） |
| `api_v1_sales` / `api_v1_inventory` | 销售 / 库存测试域暴露层 | 仅见于 `gateway/postgrest/postgrest.conf` **参考文件**的 `db-schemas = "api_v1_public, api_v1_sales, api_v1_inventory"`（与运行态不一致）；`db/api_v1/` 目录含 `_shared` / `inventory` / `public` 子目录；⚠️ 当前 `db/init` 未建这两个 schema，路由已于 2026-08-15 退役——实际启用仅 `api_v1_public` |
| `api_v1_sys` | 历史迁移引用承载 | 027 改名链兼容，遗留空 schema，新代码不再使用 |
| `net` | pg_net 扩展宿主 schema | 权限收紧：`authenticated` 无 EXECUTE/USAGE，HTTP 调用一律经 SECURITY DEFINER 封装函数 |

代码目录：`db/migrations/public`（dbmate 迁移）、`db/src/public`（函数/触发器/类型/视图/RLS）、`db/api_v1/`（`_shared` / `inventory`（空目录） / `public`（当前唯一有效暴露代码，44 RPC + 29 视图））、`db/init`（扩展 + schema 引导）、`db/tests`（pgTAP）。

**刻意保留的兼容视图**（非"未清理的 sys_ 残留"）：`public.sys_user`（users + user_profile 投影，`password_hash` 恒 NULL——密码由 Logto 管理，兼容旧查询字段）与 `public.casbin_rule`（055 双段投影：API 段 = `iam_role_menu → iam_menu` 按钮行端点，菜单段 = router）是历史接口的兼容层，源码见 `db/src/public/views/`。

## PostgreSQL 扩展清单（按 `db/init/01-extensions.sql` 实列）

### 已启用最小集（apply-src 依赖）

| 扩展 | 用途 |
| --- | --- |
| `pg_pwhash` | 密码哈希（Argon2id，OWASP 首选，抗 GPU/ASIC） |
| `pgcrypto` | 辅助加密函数（sha256 等，仅用于非密码场景） |
| `pg_net` | 异步 HTTP 请求（webhook 回调、pg_notify 增强） |
| `pgtap` | pgTAP 单元测试框架 |

### Pigsty 集群级安装（不在 01-extensions.sql）

| 扩展 | 用途 |
| --- | --- |
| `pg_cron` | 定时任务（`cron.job`/`cron.job_run_details`，经 `rpc_list_cron_jobs` 等只读 RPC 暴露） |
| `pg_graphql` | PG 原生 GraphQL（预留，暂未用于业务 API） |

### 退役 / 不启用

| 扩展 | 处置 |
| --- | --- |
| `pgaudit` | 已装但**不启用**（不配 GUC 即不生效；2026-08-05 用户决策：现有 `audit_log` 表体系已够用；01-extensions.sql 头注释已标"已移除"） |
| `pgsodium` | 2026-08-16 退役（全项目零使用） |
| `pg_smtp_client` | 弃用（上游已归档，改用 pg_net + HTTP 邮件 API） |
| `plpython3u` | 不再使用（JWT 签发已由 Logto 承担） |
| `pgjwt` | 不引入（验签在网关 APISIX，PG 内无需验签） |

> ⚠️ **已知不一致（TODO）**：`infra/pigsty.yml` 的 `pg_extensions` / `pg_databases.extensions` 仍列出 `pgaudit`、`pgsodium` 以及 24 号文档拍板的 safeupdate / plpgsql_check / pg_jsonschema / omni_csv / pgmemento / pg_mockable / jsquery / index_advisor / pg_repack——与 `db/init/01-extensions.sql` 的最小集存在差异，需以 01-extensions.sql 为准并同步 infra 配置。

## PostgREST：职责与限制

- **职责**：把暴露层 schema 的视图/RPC 自动映射为 REST 接口。**运行态以 `gateway/docker-compose.yml` 为权威**：`PGRST_DB_SCHEMAS=api_v1_public`（单 schema，仅系统管理域）、`PGRST_DB_EXTRA_SEARCH_PATH=api_v1_public,public`、`PGRST_MAX_ROWS=1000`、`PGRST_DB_PRE_REQUEST` 已清空。`gateway/postgrest/postgrest.conf` 为**参考文件**（其 `db-schemas = "api_v1_public, api_v1_sales, api_v1_inventory"` 多 schema、`roles[0]` 等与运行态不一致，引用时以 compose 为运行态权威）。OpenAPI spec 由 Swagger UI（8082）消费，宿主端口 3100（容器内 3000）。
- **JWT**：`jwt-secret = $(JWKS_JSON)`（postgrest.conf；compose 运行态 `PGRST_JWT_SECRET=${JWKS_JSON}`，取自 `gateway/.env`；开发环境 HS256 对称密钥，staging/production 指向 Logto JWKS 公钥）；`db-anon-role = web_anon`（postgrest.conf；compose `PGRST_DB_ANON_ROLE=web_anon`）；`PGRST_JWT_ROLE_CLAIM_KEY=.pg_role`（compose 运行态；参考文件 `postgrest.conf` 为 `roles[0]`）；claims 注入 `request.jwt.claims`，RLS 与 `has_permission` 直接消费。
- **限制与约定**：
  - 视图只读、无行为——涉及业务规则/写路径必须走 RPC（`has_permission` 门槛）；
  - 聚合开关开启（`PGRST_DB_AGGREGATES_ENABLED=true`）、`db-tx-end=commit`；
  - `PGRST_DB_PRE_REQUEST` 已清空——会话/吊销交 Logto，不再有 token 黑名单预检函数。

## APISIX：网关职责与插件

- **模式**：traditional（etcd 存储配置），Admin API（9180）+ 内置 Dashboard（`/ui`）+ Status API（7085）；`gateway/apisix/apisix.yaml` 为旧 standalone 模式留档，不再加载。
- **插件**：`jwt-auth`（Logto JWKS 验签；开发环境 HS256，生产 RS256）、`serverless-pre-function`（webhook HMAC-SHA256 原始 body 验签）、`proxy-rewrite`（路径映射）、全局 `cors`。
- **目标路由集**（Logto 版，`scripts/init-apisix-routes.sh`，7 条）：`/api/v1/sys/*` 经 proxy-rewrite（regex `^/api/v1/sys/(.*) → /$1`）重写至 PostgREST 的 api_v1_public 暴露层：

| 优先级 | 路由 | 说明 |
| --- | --- | --- |
| 100 | `/.well-known/jwks` | 公开：代理 Logto JWKS |
| 95 | `POST /rpc/webhook_logto` | 公开（无 jwt-auth）：Logto webhook 接收入口，APISIX 前置 HMAC 验签 |
| 80 | `POST /rpc/ensure_user` | JWT 保护：登录 JIT 建档 |
| 60 | `/logto/*` | Logto 同源代理（前端 SDK endpoint） |
| 50 | `/api/v1/sys/*` | JWT 保护：业务 API（api_v1_public） |
| 40 | `/rpc/*` | JWT 保护：其余 RPC |
| 10 | `/*` | 兜底（AuthN 准入） |

> `api_v1_sales` / `api_v1_inventory` 路由已于 2026-08-15 退役移除（对应 schema 亦未在 `db/init` 创建）。

### APISIX：已知不一致/待收敛

| 文件 | 定位 | 现状 |
| --- | --- | --- |
| `scripts/init-apisix-routes.sh` | **目标架构路由脚本**（Logto 版：logto_jwks → app-logto:3001、logto_proxy `/logto/*`、webhook_logto `/rpc/webhook_logto`（HMAC 验签）、ensure_user `/rpc/ensure_user`、api_v1_public `/api/v1/sys/*`、rpc_all `/rpc/*`、catch_all `/*`） | 未被 Makefile/部署链调用；仅 `scripts/e2e-test.sh` 注释中作为前置说明引用（期望上述路由已就位） |
| `scripts/setup_apisix.sh` | **Casdoor 时代旧脚本残留**（jwks 上游 `app-casdoor:8000` 已死、user_login_sso / refresh_token_rtr、api_v1_sales / api_v1_inventory 重写；HS256 元数据） | 仍被 `Makefile dev`、`scripts/deploy-all.sh`、`.github/workflows/deploy-gateway.yml` 调用——与 Logto 部署不一致，**待收敛**（部署链应切换到 init-apisix-routes.sh） |
| `gateway/apisix/apisix.yaml` | **过时残留**（standalone 模式声明式路由，含 Casdoor 时代 `/rpc/user_login_sso`、`/rpc/refresh_token_rtr`、`/well-known/jwks`、`/api/v1/sales/*`、`/api/v1/inventory/*`） | `gateway/apisix/config.yaml` 已切 traditional（etcd + Admin API），注释明确"不再读取 apisix.yaml"——请勿当现行路由表使用 |

## Logto：认证授权职责

- **认证**：密码 / 验证码 / 微信网页扫码（wechat-web）/ 微信原生 App（wechat-native）等连接器；MFA；密码策略与登录限速由 Logto Console 配置。
- **组织（租户）**：Logto Organization 是一等实体，作为租户容器与成员关系真相源；组织 token 内置 `organization_id` claim（refresh token flow 换取）。
- **角色**：全局角色（`Role`，type=User）+ 组织角色（OrganizationRole）；角色目录 CRUD 与"用户↔角色 / 组织成员↔组织角色"分配由 Logto 管理；Custom Token Claims 脚本从 context 提取角色注入 `roles` claim（零 fetch）。
- **同步**：Webhook 事件（`User.*` / `Organization.*` / `Organization.Membership.Updated` / `Role.*` / `OrganizationRole.*` / `PostSignIn`）→ APISIX 验签 → `rpc_webhook_logto` → 库内 `sync_*` 函数维护镜像表与登录日志。
- **边界**：Logto **不参与授权判定**——路由级角色检查（可选 `required_roles`）、操作级 `has_permission`、数据级 RLS 全部在 PG/网关执行；会话吊销由 Logto 原生管理（无自建 `sys_user_session` / token 黑名单）。

## 开发工具链

| 工具 | 用法 | 说明 |
| --- | --- | --- |
| dbmate | `make migrate` / `make migrate-rollback` / `make migrate-status` | 迁移目录 `db/migrations/public`，连接串来自 `gateway/.env` 的 `DB_PASSWORD` |
| pgTAP | `make test-db`（`pg_prove -r db/tests`） | 测试文件：schema / function / trigger / RLS / casbin 视图等 |
| E2E | `make test-e2e` → `scripts/e2e-test.sh` | 端到端集成测试 |
| 冒烟 | `scripts/verify-stack.sh`、`scripts/verify-fresh-db.sh` | 服务健康与全新库验证 |
| SQL lint | sqlfluff（CI `db-lint` job） | `db/migrations`、`db/src` 扫描 |
| 一键开发 | `make dev`（compose up + `scripts/setup_apisix.sh`） | ⚠️ 当前仍调用旧 `setup_apisix.sh`（Casdoor 时代残留），预期改为 `scripts/init-apisix-routes.sh`（Logto 版），见「APISIX：已知不一致/待收敛」 |

## 多环境说明

| 环境 | 配置文件 | APP_ENV | 敏感值 | JWT 密钥 |
| --- | --- | --- | --- | --- |
| development | `.env.development`（复制为 `gateway/.env`） | `development` | 内置开发默认值 | HS256 对称密钥（`JWKS_JSON`） |
| staging | `.env.staging` | `staging` | `${VAR}` 环境变量注入 | Logto JWKS 公钥（RS256，05 文档/init 脚本口径；compose 注释另写 ES384，需以 Logto 实际配置核实） |
| production | `.env.production` | `production` | `${VAR}` 注入或密钥管理服务 | 同上 |

- 部署入口：`scripts/deploy-db.sh <env> [db_port]`（bootstrap → dbmate up → apply-src 全量重放 → 验证）、`scripts/deploy-gateway.sh <env>`（复制 `.env.<env>` → compose 重启 → 健康检查）、`scripts/deploy-infra.sh`；CI 侧对应 `deploy-db.yml` / `deploy-gateway.yml` / `deploy-infra.yml` / `deploy-all.yml`（workflow_dispatch，staging/production）。
- 端口速查（开发环境）：APISIX 9080/9443/9180/7085 · PostgREST 3100 · Logto 3001(core)/3002(console) · Swagger 8082 · PostgreSQL 5432 · pgBouncer 6432 · Redis 6379 · Logto 业务库 5433（宿主 Pigsty PG）。
- 环境差异注意：APISIX Admin Key、数据库密码、JWKS 全部经 `.env.<env>` 注入，任何非本地部署前必须更换默认值（如 `openssl rand -hex 16`）。

---

> 参考：[项目简介](overview.md) · [部署与环境配置](../03-部署指南/environment-config.md) · [PostgREST 使用指南](../06-API参考/postgrest.md) · [网关路由](../06-API参考/gateway-routing.md) · [数据库迁移](../05-开发指南/migrations.md) · [pgTAP 测试指南](../07-测试/pgtap-guide.md)